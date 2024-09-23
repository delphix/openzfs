// Copyright (c) 2023 by Delphix. All rights reserved.
package main

// #include <string.h>
import "C"
import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"unsafe"

	"cloud.google.com/go/storage"
	log "github.com/sirupsen/logrus"
	"github.com/sirupsen/logrus/hooks/writer"
	"golang.org/x/oauth2/google"
	"google.golang.org/api/googleapi"
	"google.golang.org/api/iterator"
	"gopkg.in/natefinch/lumberjack.v2"
)

//export GCPSetupLogging
func GCPSetupLogging(level C.uint, path *C.char) {
	switch level {
	case 0:
		log.SetLevel(log.WarnLevel)
	case 1:
		log.SetLevel(log.InfoLevel)
	case 2:
		log.SetLevel(log.DebugLevel)
	default:
		log.SetLevel(log.TraceLevel)
	}

	if path != nil {
		go_path := C.GoString(path)
		f, err := os.OpenFile(go_path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0644)
		FatalIfError(err)
		log.SetOutput(f)
	} else {
		log.SetOutput(os.Stdout)
	}
}

//export GCPSetupDefaultLogging
func GCPSetupDefaultLogging() {
	log.SetLevel(log.DebugLevel)

	log.SetFormatter(&log.TextFormatter{})

	log.SetOutput(io.Discard)
	log.AddHook(&writer.Hook{
		Writer: os.Stderr,
		LogLevels: []log.Level{
			log.PanicLevel,
			log.FatalLevel,
			log.ErrorLevel,
		},
	})
	log.AddHook(&writer.Hook{
		Writer: &lumberjack.Logger{
			Filename: "/var/log/zoa/go_debug.log",
			MaxSize:  50,
			Compress: false,
		},
		LogLevels: []log.Level{
			log.DebugLevel,
			log.InfoLevel,
			log.WarnLevel,
			log.ErrorLevel,
			log.FatalLevel,
			log.PanicLevel,
		},
	})
	log.AddHook(&writer.Hook{
		Writer: &lumberjack.Logger{
			Filename: "/var/log/zoa/go_info.log",
			MaxSize:  50,
			Compress: false,
		},
		LogLevels: []log.Level{
			log.InfoLevel,
			log.WarnLevel,
			log.ErrorLevel,
			log.FatalLevel,
			log.PanicLevel,
		},
	})
	log.AddHook(&writer.Hook{
		Writer: &lumberjack.Logger{
			Filename: "/var/log/zoa/go_warn.log",
			MaxSize:  50,
			Compress: false,
		},
		LogLevels: []log.Level{
			log.WarnLevel,
			log.ErrorLevel,
			log.FatalLevel,
			log.PanicLevel,
		},
	})
	log.AddHook(&writer.Hook{
		Writer: &lumberjack.Logger{
			Filename: "/var/log/zoa/go_error.log",
			MaxSize:  50,
			Compress: false,
		},
		LogLevels: []log.Level{
			log.ErrorLevel,
			log.FatalLevel,
			log.PanicLevel,
		},
	})
}

type ClientInfo struct {
	client            storage.Client
	rate_limit_errors atomic.Uint64
}

type GlobalState struct {
	lock       sync.RWMutex
	clients    map[C.uint]*ClientInfo
	listPagers map[C.ulong]*iterator.Pager
	prevId     C.uint
	prevToken  C.ulong
}

func (g *GlobalState) InsertClient(clientInfo *ClientInfo) C.uint {
	g.lock.Lock()
	defer g.lock.Unlock()
	g.prevId++
	g.clients[g.prevId] = clientInfo
	return g.prevId
}

func (g *GlobalState) GetClient(cid C.uint) *ClientInfo {
	g.lock.RLock()
	defer g.lock.RUnlock()
	return g.clients[cid]
}

func (g *GlobalState) DeleteClient(cid C.uint) {
	g.lock.Lock()
	defer g.lock.Unlock()
	delete(g.clients, cid)
}

func (g *GlobalState) InsertPager(pager *iterator.Pager) C.ulong {
	g.lock.Lock()
	defer g.lock.Unlock()
	g.prevToken++
	g.listPagers[g.prevToken] = pager
	return g.prevToken
}

func (g *GlobalState) GetPager(token C.ulong) *iterator.Pager {
	g.lock.RLock()
	defer g.lock.RUnlock()
	return g.listPagers[token]
}

func (g *GlobalState) DeletePager(token C.ulong) {
	g.lock.Lock()
	defer g.lock.Unlock()
	delete(g.listPagers, token)
}

var globalState GlobalState = GlobalState{
	clients:    make(map[C.uint]*ClientInfo),
	listPagers: make(map[C.ulong]*iterator.Pager),
}

// Exactly one of these must be non-nil.
type Result struct {
	Ok  any       `json:",omitempty"`
	Err *SdkError `json:",omitempty"`
}

// Exactly one of these must be non-nil.
type SdkError struct {
	Other        *string       `json:",omitempty"`
	ServiceError *ServiceError `json:",omitempty"`
}

type ServiceError struct {
	HttpStatusCode int
	Code           string
	Message        string
}

func NewResult(ok any, err error) Result {
	if err == nil {
		if ok == nil {
			log.Panic("Result: both ok and err are nil")
		}
		return Result{Ok: ok}
	} else {
		var e *googleapi.Error
		var sdk_error SdkError
		if ok := errors.As(err, &e); ok {
			sdk_error = SdkError{ServiceError: &ServiceError{
				HttpStatusCode: e.Code,
				Message:        e.Message,
			}}
		} else {
			error_string := err.Error()
			sdk_error = SdkError{Other: &error_string}
		}
		return Result{Err: &sdk_error}
	}
}

func ReturnResult(ok any, err error) (*C.char, C.longlong) {
	result := NewResult(ok, err)
	log.Tracef("ReturnResult[%T] res: %v\n", ok, result)
	jsonData, err := json.Marshal(result)
	FatalIfError(err)
	return (*C.char)(C.CBytes(jsonData)), C.longlong(len(jsonData))
}

func ReturnErr(err error) (*C.char, C.longlong) {
	return ReturnResult(nil, err)
}

func GetRequest[T any](json_ptr *C.char) T {
	json_string := C.GoString(json_ptr)
	var req T
	log.Tracef("GetRequest[%T] string: %v\n", req, json_string)
	err := json.Unmarshal([]byte(json_string), &req)
	FatalIfError(err)
	log.Tracef("GetRequest[%T] req: %v\n", req, req)
	return req
}

func FatalIfError(err error) {
	if err != nil {
		stack := debug.Stack()
		log.Fatal(err, " ", string(stack))
	}
}

func NewGCPClientInfo() ClientInfo {
	ctx := context.Background()
	client, err := storage.NewClient(ctx)
	FatalIfError(err)
	return ClientInfo{*client, atomic.Uint64{}}
}

//export NewGCPClient
func NewGCPClient() C.uint {
	clientInfo := NewGCPClientInfo()

	// by default, all methods follow the retry best practices https://pkg.go.dev/cloud.google.com/go/storage#hdr-Retrying_failed_requests
	// However, there are some errors that we've encountered that are not retried by default that should be.
	// In addition, we need to track the rate limit errors we encounter.

	retryCountRateLimitErrors := func(err error) bool {
		if err == nil {
			return false
		}
		if strings.Contains(err.Error(), "address family not supported by protocol") ||
			strings.Contains(err.Error(), "write: broken pipe") ||
			strings.Contains(err.Error(), "client connection lost") ||
			strings.Contains(err.Error(), "client connection force closed") ||
			strings.Contains(err.Error(), "bad record MAC") {
			return true

		}
		var e *googleapi.Error
		if ok := errors.As(err, &e); ok {
			if e.Code == 429 {
				clientInfo.rate_limit_errors.Add(1)
			}
		}
		// https://pkg.go.dev/cloud.google.com/go/storage#ShouldRetry
		return storage.ShouldRetry(err)
	}

	// store client in a global map (we can't pass back structs with embedded pointers)
	clientInfo.client.SetRetry(storage.WithPolicy(storage.RetryAlways), storage.WithErrorFunc(retryCountRateLimitErrors))
	cid := globalState.InsertClient(&clientInfo)
	log.WithField("cid", cid).Debug("NewGCPClient()")
	return C.uint(cid)
}

func GetProjectId() string {
	ctx := context.Background()
	credentials, err := google.FindDefaultCredentials(ctx, storage.ScopeFullControl)
	if err != nil {
		log.WithError(err).Error("GetProjectId()")
	}
	return credentials.ProjectID
}

//export DeleteGCPClient
func DeleteGCPClient(cid C.uint) {
	log.WithField("cid", cid).Info("deleting client")
	globalState.DeleteClient(cid)
}

type CWriter struct {
	buf  *C.char
	len  int
	next int
}

func (w *CWriter) Write(p []byte) (int, error) {
	if w.next >= w.len {
		return 0, io.EOF
	}
	var err error
	n := len(p)
	buf_remaining := w.len - w.next
	if n > buf_remaining {
		n = buf_remaining
		err = io.EOF
	}
	C.memcpy(
		unsafe.Add(unsafe.Pointer(w.buf), w.next),
		unsafe.Pointer(&p[0]),
		C.size_t(n),
	)
	w.next += n
	return n, err
}

// Allocate a new CWriter.  Caller must free the buf with C.free(w.Buf())
func NewCWriter(len int) *CWriter {
	buf := (*C.char)(C.malloc(C.size_t(len)))
	return &CWriter{buf, len, 0}
}

type GetObjectRequest struct {
	Bucket     string
	ObjectName string
	RangeStart uint64
	RangeEnd   uint64
}

// returns (buf1, len1, buf2, len2).  buf1 is the json response, buf2 is the object contents, while len1 and len2
// are the length of the respsective buffers. The bufs must be freed with libc.free().
//
//export GCPClientGetObject
func GCPClientGetObject(cid C.uint, json_ptr *C.char) (*C.char, C.longlong, *C.char, C.longlong) {
	req := GetRequest[GetObjectRequest](json_ptr)
	clientInfo := globalState.GetClient(cid)
	var reader *storage.Reader
	var err error
	len := int64(0)
	for {
		if req.RangeEnd != 0 {
			len = int64(req.RangeEnd - req.RangeStart)
			reader, err = clientInfo.client.Bucket(req.Bucket).Object(req.ObjectName).NewRangeReader(context.Background(), int64(req.RangeStart), int64(len))
		} else {
			reader, err = clientInfo.client.Bucket(req.Bucket).Object(req.ObjectName).NewReader(context.Background())
		}
		if err != nil {
			log.WithField("error", err).Info("GetObject error")
			resp_json_ptr, resp_json_len := ReturnErr(err)
			return resp_json_ptr, resp_json_len, nil, 0
		}

		resp_json_ptr, resp_json_len := ReturnResult(reader.Attrs, err)

		if len == 0 {
			len = reader.Attrs.Size
		}
		writer := NewCWriter(int(len))
		// TODO: This ads an extra copy since the writer doesn't implement ReaderFrom and the content doesn't implement WriterTo.
		// We could fix this by implementing ReaderFrom in CWriter but 1) it's not a great fit, and 2) the performance seems
		// to be acceptable without it.
		_, copy_err := io.Copy(writer, reader)
		if copy_err != nil {
			continue
		}
		reader.Close()

		return resp_json_ptr, resp_json_len, writer.buf, C.longlong(len)
	}
}

type CReader struct {
	buf  *C.char
	len  int
	next int
}

func (r *CReader) Read(p []byte) (int, error) {
	if r.next >= r.len {
		return 0, io.EOF
	}
	n := r.len - r.next
	if n > len(p) {
		n = len(p)
	}
	C.memcpy(
		unsafe.Pointer(&p[0]),
		unsafe.Add(unsafe.Pointer(r.buf), r.next),
		C.size_t(n),
	)
	r.next += n
	return n, nil
}

func (r *CReader) Seek(offset int64, whence int) (int64, error) {
	switch whence {
	case io.SeekStart:
		r.next = int(offset)
	case io.SeekCurrent:
		r.next += int(offset)
	case io.SeekEnd:
		r.next = r.len - int(offset)
	}
	return int64(r.next), nil
}

func NewCReader(buf *C.char, len int) *CReader {
	return &CReader{buf, len, 0}
}

type PutObjectRequest struct {
	Bucket     string
	ObjectName string
}

type PutObjectResponse struct {
	Attrs storage.ObjectAttrs
}

// ref: https://pkg.go.dev/cloud.google.com/go/storage#ObjectHandle.NewWriter
//
//export GCPClientPutObject
func GCPClientPutObject(cid C.uint, json_ptr *C.char, buf_ptr *C.char, buf_len C.int) (*C.char, C.longlong) {
	req := GetRequest[PutObjectRequest](json_ptr)
	clientInfo := globalState.GetClient(cid)

	reader := NewCReader(buf_ptr, int(buf_len))
	log.WithFields(log.Fields{
		"cid":    cid,
		"object": req.ObjectName,
		"length": buf_len,
	}).Debug("GCPClientPutObject")

	// https://pkg.go.dev/cloud.google.com/go/storage#Writer explains the various parameters.
	writer := clientInfo.client.Bucket(req.Bucket).Object(req.ObjectName).NewWriter(context.Background())
	writer.ChunkSize = int(buf_len + 128) // They suggest we set it to "Slightly larger than the objects' size".
	_, err := io.Copy(writer, reader)
	if err != nil {
		log.WithField("error", err).Info("PutObject error")
	} else {
		err = writer.Close()
		if err != nil {
			log.WithField("error", err).Info("PutObject writer close error")
			return ReturnErr(err)
		}
		my_resp := GetObjectAttrsResponse{
			Attrs: *writer.Attrs(),
		}
		return ReturnResult(my_resp, err)
	}

	return ReturnErr(err)
}

type DeleteObjectRequest struct {
	Bucket     string
	ObjectName string
}

// ref: https://pkg.go.dev/cloud.google.com/go/storage#ObjectHandle.Delete
//
//export GCPClientDeleteObject
func GCPClientDeleteObject(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	req := GetRequest[DeleteObjectRequest](json_ptr)
	clientInfo := globalState.GetClient(cid)
	log.WithFields(log.Fields{
		"cid":    cid,
		"object": req.ObjectName,
	}).Debug("GCPClientDeleteObject")
	err := clientInfo.client.Bucket(req.Bucket).Object(req.ObjectName).Delete(context.Background())
	if err != nil {
		log.WithField("error", err).Info("DeleteObject error")
	}
	return ReturnResult(1, err)
}

type ListObjectsRequest struct {
	Bucket    string
	Prefix    *string
	StartAt   *string
	Delimiter *string
	Token     C.ulong
}

type ListObjectsResponse struct {
	Items []*storage.ObjectAttrs
	Token C.ulong
}

// ref: https://pkg.go.dev/cloud.google.com/go/storage#BucketHandle.Objects
//
//export GCPClientListObjects
func GCPClientListObjects(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	req := GetRequest[ListObjectsRequest](json_ptr)
	if req.Token != 0 {
		pager := globalState.GetPager(req.Token)
		var slice []*storage.ObjectAttrs
		token, err := pager.NextPage(&slice)
		if err != nil {
			log.WithField("error", err).Warn("ListObjects error")
			globalState.DeletePager(req.Token)
			return ReturnErr(err)
		}
		if token == "" {
			globalState.DeletePager(req.Token)
			req.Token = 0
		}
		my_resp := ListObjectsResponse{
			Items: slice,
			Token: req.Token,
		}
		return ReturnResult(my_resp, nil)
	}

	clientInfo := globalState.GetClient(cid)
	query := storage.Query{}
	if req.Prefix != nil {
		query.Prefix = *req.Prefix
	}
	if req.Delimiter != nil {
		query.Delimiter = *req.Delimiter
	}
	// This is the starting point of the iteration; while other object store start
	// *after* a field like this, GCP starts *at* this field. We handle the behavioral
	// difference in the Rust code.
	if req.StartAt != nil {
		query.StartOffset = *req.StartAt
	}
	it := clientInfo.client.Bucket(req.Bucket).Objects(context.Background(), &query)
	pager := iterator.NewPager(it, 1000, "")
	var slice []*storage.ObjectAttrs
	token, err := pager.NextPage(&slice)
	if err != nil {
		log.WithField("error", err).Info("ListObjects error")
	}

	var returnToken C.ulong = 0
	if token != "" {
		returnToken = globalState.InsertPager(pager)
	}

	my_resp := ListObjectsResponse{
		Items: slice,
		Token: returnToken,
	}
	return ReturnResult(my_resp, err)
}

type GetObjectAttrsRequest struct {
	Bucket     string
	ObjectName string
}

type GetObjectAttrsResponse struct {
	Attrs storage.ObjectAttrs
}

//export GCPClientGetObjectAttrs
func GCPClientGetObjectAttrs(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	req := GetRequest[GetObjectAttrsRequest](json_ptr)
	clientInfo := globalState.GetClient(cid)

	attrs, err := clientInfo.client.Bucket(req.Bucket).Object(req.ObjectName).Attrs(context.Background())
	if err != nil {
		log.WithField("error", err).Info("GetObjectAttrs error")
		return ReturnErr(err)
	}
	my_resp := GetObjectAttrsResponse{
		Attrs: *attrs,
	}
	return ReturnResult(my_resp, err)
}

type GetBucketAttrsRequest struct {
	Bucket string
}

type GetBucketAttrsResponse struct {
	Attrs storage.BucketAttrs
}

// refs:
//
//	https://pkg.go.dev/cloud.google.com/go/storage#BucketHandle.Attrs
//
//export GCPClientGetBucketAttrs
func GCPClientGetBucketAttrs(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	req := GetRequest[GetBucketAttrsRequest](json_ptr)
	clientInfo := globalState.GetClient(cid)
	bucket := clientInfo.client.Bucket(req.Bucket)
	attrs, err := bucket.Attrs(context.Background())
	if err != nil {
		log.WithField("error", err).Info("bucket.Attrs error")
		return ReturnErr(err)
	}
	my_resp := GetBucketAttrsResponse{
		Attrs: *attrs,
	}
	return ReturnResult(my_resp, err)
}

type ListBucketsResponse struct {
	Items []storage.BucketAttrs
}

//export GCPClientListBuckets
func GCPClientListBuckets(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	clientInfo := globalState.GetClient(cid)
	projectId := GetProjectId()
	it := clientInfo.client.Buckets(context.Background(), projectId)
	pager := iterator.NewPager(it, 1000, "")
	var slice []storage.BucketAttrs
	for token, err := pager.NextPage(slice); token != "" && err == nil; token, err = pager.NextPage(slice) {
	}

	my_resp := ListBucketsResponse{
		Items: slice,
	}
	return ReturnResult(my_resp, nil)
}

//export GCPTakeRateLimitErrors
func GCPTakeRateLimitErrors(cid C.uint) C.ulong {
	clientInfo := globalState.GetClient(cid)
	return C.ulong(clientInfo.rate_limit_errors.Swap(0))
}

func main() {} // reqired for main package
