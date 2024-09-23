// Copyright (c) 2023 by Delphix. All rights reserved.
package main

// #include <string.h>
import "C"
import (
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	log "github.com/sirupsen/logrus"
	"github.com/sirupsen/logrus/hooks/writer"
	"gopkg.in/natefinch/lumberjack.v2"

	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/common/auth"
	"github.com/oracle/oci-go-sdk/v65/objectstorage"
)

//export OCISetupLogging
func OCISetupLogging(level C.uint, path *C.char) {
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

//export OCISetupDefaultLogging
func OCISetupDefaultLogging() {
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
	client            objectstorage.ObjectStorageClient
	rate_limit_errors atomic.Uint64
}

type GlobalState struct {
	lock    sync.RWMutex
	clients map[C.uint]*ClientInfo
	prev_id C.uint
}

func (g *GlobalState) Insert(clientInfo *ClientInfo) C.uint {
	g.lock.Lock()
	defer g.lock.Unlock()
	g.prev_id++
	g.clients[g.prev_id] = clientInfo
	return g.prev_id
}

func (g *GlobalState) Get(cid C.uint) *ClientInfo {
	g.lock.RLock()
	defer g.lock.RUnlock()
	return g.clients[cid]
}

func (g *GlobalState) Delete(cid C.uint) {
	g.lock.Lock()
	defer g.lock.Unlock()
	delete(g.clients, cid)
}

var globalState GlobalState = GlobalState{clients: make(map[C.uint]*ClientInfo)}

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
		se, is_se := common.IsServiceError(err)
		var sdk_error SdkError
		if is_se {
			sdk_error = SdkError{ServiceError: &ServiceError{
				HttpStatusCode: se.GetHTTPStatusCode(),
				Code:           se.GetCode(),
				Message:        se.GetMessage(),
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

func GetRequest[T any](json_ptr *C.char) T {
	json_string := C.GoString(json_ptr)
	var req T
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

func NewOCIClientInfo() ClientInfo {
	// Use an instance principal provider
	provider, err := auth.InstancePrincipalConfigurationProvider()
	FatalIfError(err)
	client, err := objectstorage.NewObjectStorageClientWithConfigurationProvider(provider)
	FatalIfError(err)
	return ClientInfo{client, atomic.Uint64{}}
}

//export NewOCIClient
func NewOCIClient() C.uint {
	clientInfo := NewOCIClientInfo()

	retryCountRateLimitErrors := func(r common.OCIOperationResponse) bool {
		if r.Error == nil && r.Response.HTTPResponse().StatusCode == 429 {
			clientInfo.rate_limit_errors.Add(1)
		}
		// The DefaultShouldRetryOperation is supposed to return true for ephemeral network errors.
		// However, it appears to rely on a deprecated function to determine if the error is
		// ephemeral, and so sometimes we fail to retry ephemeral errors. On other cloud platforms
		// we simply retry all network failures, obviously ephemeral or otherwise, so rather than
		// trying to patch individual failures as they occur, we adopt that approach here as well.
		if r.Error != nil {
			log.WithField("error", r.Error).Debug("ShouldRetry checking")
			if _, ok := r.Error.(net.Error); ok {
				return true
			}
		}
		return common.DefaultShouldRetryOperation(r)
	}
	retryPolicy := common.DefaultRetryPolicyWithoutEventualConsistency()
	common.WithUnlimitedAttempts(time.Duration(24 * time.Hour))(&retryPolicy)
	common.WithExponentialBackoff(time.Duration(10*time.Second), 2)(&retryPolicy)
	common.WithShouldRetryOperation(retryCountRateLimitErrors)(&retryPolicy)

	clientInfo.client.SetCustomClientConfiguration(common.CustomClientConfiguration{
		RetryPolicy:    &retryPolicy,
		CircuitBreaker: common.NewCircuitBreaker(common.NoCircuitBreakerSetting()),
	})

	// store client in a global map (we can't pass back structs with embedded pointers)
	cid := globalState.Insert(&clientInfo)
	log.WithField("cid", cid).Info("NewOCIClient()")
	return C.uint(cid)
}

//export DeleteOCIClient
func DeleteOCIClient(cid C.uint) {
	log.WithField("cid", cid).Info("deleting client")
	globalState.Delete(cid)
}

// This function checks if the error returned by an SDK call is one that we should retry.
// The instance principal authentication method we use has tokens that expire after fifteen minutes;
// if the token expires after the request is issued, we can get a one-off NotAuthenticated failure.
// If that happens, we should retry a single time; further failures must be indicative of a larger
// problem, and should be handled by the normal agent logic.
func should_retry(err error) bool {
	if err == nil {
		return false
	}
	se, is_se := common.IsServiceError(err)
	return is_se && se.GetCode() == "NotAuthenticated"
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

// ref: https://sourcegraph.com/github.com/oracle/oci-go-sdk/-/blob/objectstorage/get_object_request_response.go
// returns (buf1, len1, buf2, len2).  buf1 is the json response, buf2 is the object contents, while len1 and len2
// are the length of the respsective buffers. The bufs must be freed with libc.free().
//
//export OCIClientGetObject
func OCIClientGetObject(cid C.uint, json_ptr *C.char) (*C.char, C.longlong, *C.char, C.longlong) {
	req := GetRequest[objectstorage.GetObjectRequest](json_ptr)
	clientInfo := globalState.Get(cid)
	for {
		resp, err := clientInfo.client.GetObject(context.Background(), req)
		if should_retry(err) {
			log.WithField("object", req.ObjectName).Debug("retrying getobject")
			resp, err = clientInfo.client.GetObject(context.Background(), req)
		}
		if err != nil {
			log.WithField("error", err).Info("GetObject error")
		}

		// same as objectstorage.GetObjectResponse, but without the non-marshallable fields
		type GetObjectResponse struct {
			OpcClientRequestId *string
			OpcRequestId       *string
			ETag               *string
			OpcMeta            map[string]string
			ContentLength      *int64
			ContentRange       *string
			ContentMd5         *string
			OpcMultipartMd5    *string
			ContentType        *string
			ContentLanguage    *string
			ContentEncoding    *string
			CacheControl       *string
			ContentDisposition *string
			LastModified       *common.SDKTime
			StorageTier        objectstorage.GetObjectStorageTierEnum
			ArchivalState      objectstorage.GetObjectArchivalStateEnum
			TimeOfArchival     *common.SDKTime
			VersionId          *string
			Expires            *common.SDKTime
			IsNotModified      bool
		}
		marshallable_resp := GetObjectResponse{
			OpcClientRequestId: resp.OpcClientRequestId,
			OpcRequestId:       resp.OpcRequestId,
			ETag:               resp.ETag,
			OpcMeta:            resp.OpcMeta,
			ContentLength:      resp.ContentLength,
			ContentRange:       resp.ContentRange,
			ContentMd5:         resp.ContentMd5,
			OpcMultipartMd5:    resp.OpcMultipartMd5,
			ContentType:        resp.ContentType,
			ContentLanguage:    resp.ContentLanguage,
			ContentEncoding:    resp.ContentEncoding,
			CacheControl:       resp.CacheControl,
			ContentDisposition: resp.ContentDisposition,
			LastModified:       resp.LastModified,
			StorageTier:        resp.StorageTier,
			ArchivalState:      resp.ArchivalState,
			TimeOfArchival:     resp.TimeOfArchival,
			VersionId:          resp.VersionId,
			Expires:            resp.Expires,
			IsNotModified:      resp.IsNotModified,
		}

		resp_json_ptr, resp_json_len := ReturnResult(marshallable_resp, err)

		if err != nil {
			return resp_json_ptr, resp_json_len, nil, 0
		}

		len := int(*resp.ContentLength)
		writer := NewCWriter(len)
		// TODO: This ads an extra copy since the writer doesn't implement ReaderFrom and the content doesn't implement WriterTo.
		// We could fix this by implementing ReaderFrom in CWriter but 1) it's not a great fit, and 2) the performance seems
		// to be acceptable without it.
		_, copy_err := io.Copy(writer, resp.Content)
		if copy_err != nil {
			continue
		}

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

// ref: https://sourcegraph.com/github.com/oracle/oci-go-sdk/-/blob/objectstorage/put_object_request_response.go
//
//export OCIClientPutObject
func OCIClientPutObject(cid C.uint, json_ptr *C.char, buf_ptr *C.char, buf_len C.int) (*C.char, C.longlong) {
	req := GetRequest[objectstorage.PutObjectRequest](json_ptr)
	clientInfo := globalState.Get(cid)

	reader := NewCReader(buf_ptr, int(buf_len))
	log.WithFields(log.Fields{
		"cid":    cid,
		"object": *req.ObjectName,
		"length": buf_len,
	}).Debug("OCIClientPutObject")

	len64 := int64(buf_len)
	// marked `mandatory:"false"` but actually required to workaround
	// https://github.com/oracle/oci-go-sdk/issues/430
	req.ContentLength = &len64
	req.PutObjectBody = io.NopCloser(reader)

	resp, err := clientInfo.client.PutObject(context.Background(), req)
	if should_retry(err) {
		log.WithField("object", *req.ObjectName).Debug("retrying putobject")
		reader.Seek(0, io.SeekStart)
		resp, err = clientInfo.client.PutObject(context.Background(), req)
	}
	if err != nil {
		log.WithField("error", err).Info("PutObject error")
	}

	// Same as storage.PutObjectResponse, but without the non-marshallable fields
	type PutObjectResponse struct {
		OpcClientRequestId *string
		OpcRequestId       *string
		OpcContentMd5      *string
		ETag               *string
		LastModified       *common.SDKTime
		VersionId          *string
	}
	marshallable_resp := PutObjectResponse{
		OpcClientRequestId: resp.OpcClientRequestId,
		OpcRequestId:       resp.OpcRequestId,
		OpcContentMd5:      resp.OpcContentMd5,
		ETag:               resp.ETag,
		LastModified:       resp.LastModified,
		VersionId:          resp.VersionId,
	}
	return ReturnResult(marshallable_resp, err)
}

//export OCIClientGetNamespace
func OCIClientGetNamespace(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	req := GetRequest[objectstorage.GetNamespaceRequest](json_ptr)
	clientInfo := globalState.Get(cid)
	resp, err := clientInfo.client.GetNamespace(context.Background(), req)
	if should_retry(err) {
		log.Info("retrying getnamespace")
		resp, err = clientInfo.client.GetNamespace(context.Background(), req)
	}
	if err != nil {
		log.WithField("error", err).Info("GetNamespace error")
	}
	return ReturnResult(resp.Value, err)
}

// ref: https://sourcegraph.com/github.com/oracle/oci-go-sdk/-/blob/objectstorage/delete_object_request_response.go
//
//export OCIClientDeleteObject
func OCIClientDeleteObject(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	req := GetRequest[objectstorage.DeleteObjectRequest](json_ptr)
	clientInfo := globalState.Get(cid)
	_, err := clientInfo.client.DeleteObject(context.Background(), req)
	if should_retry(err) {
		log.WithField("object", *req.ObjectName).Debug("retrying deleteobject")
		_, err = clientInfo.client.DeleteObject(context.Background(), req)
	}
	if err != nil {
		log.WithField("error", err).Info("DeleteObject error")
	}
	return ReturnResult(1, err)
}

// refs:
//
//	https://sourcegraph.com/github.com/oracle/oci-go-sdk/-/blob/objectstorage/list_objects_request_response.go
//	https://sourcegraph.com/github.com/oracle/oci-go-sdk/-/blob/objectstorage/list_objects.go
//	https://sourcegraph.com/github.com/oracle/oci-go-sdk/-/blob/objectstorage/object_summary.go?L23:6-23:19
//
//export OCIClientListObjects
func OCIClientListObjects(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	req := GetRequest[objectstorage.ListObjectsRequest](json_ptr)
	clientInfo := globalState.Get(cid)
	resp, err := clientInfo.client.ListObjects(context.Background(), req)
	if should_retry(err) {
		log.WithField("prefix", req.Prefix).Debug("retrying listobjects")
		resp, err = clientInfo.client.ListObjects(context.Background(), req)
	}
	if err != nil {
		log.WithField("error", err).Info("ListObjects error")
	}
	return ReturnResult(resp.ListObjects, err)
}

//export OCIClientHeadObject
func OCIClientHeadObject(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	req := GetRequest[objectstorage.HeadObjectRequest](json_ptr)
	clientInfo := globalState.Get(cid)

	resp, err := clientInfo.client.HeadObject(context.Background(), req)
	if should_retry(err) {
		log.WithField("object", *req.ObjectName).Debug("retrying headobject")
		resp, err = clientInfo.client.HeadObject(context.Background(), req)
	}
	if err != nil {
		log.WithField("error", err).Info("HeadObject error")
	}
	// Same as objectstorage.HeadObjectResponse, but without the non-marshallable fields
	type HeadObjectResponse struct {
		OpcClientRequestId *string
		OpcRequestId       *string
		ETag               *string
		OpcMeta            map[string]string
		ContentLength      *int64
		ContentMd5         *string
		OpcMultipartMd5    *string
		ContentType        *string
		ContentLanguage    *string
		ContentEncoding    *string
		CacheControl       *string
		ContentDisposition *string
		LastModified       *common.SDKTime
		StorageTier        objectstorage.HeadObjectStorageTierEnum
		ArchivalState      objectstorage.HeadObjectArchivalStateEnum
		TimeOfArchival     *common.SDKTime
		VersionId          *string
		IsNotModified      bool
	}
	head_object := HeadObjectResponse{
		ETag:               resp.ETag,
		OpcMeta:            resp.OpcMeta,
		ContentLength:      resp.ContentLength,
		ContentMd5:         resp.ContentMd5,
		OpcMultipartMd5:    resp.OpcMultipartMd5,
		ContentType:        resp.ContentType,
		ContentLanguage:    resp.ContentLanguage,
		ContentEncoding:    resp.ContentEncoding,
		CacheControl:       resp.CacheControl,
		ContentDisposition: resp.ContentDisposition,
		LastModified:       resp.LastModified,
		StorageTier:        resp.StorageTier,
		ArchivalState:      resp.ArchivalState,
		TimeOfArchival:     resp.TimeOfArchival,
		VersionId:          resp.VersionId,
		IsNotModified:      resp.IsNotModified,
	}

	return ReturnResult(head_object, err)
}

type GetObjectLifecyclePolicyResponse struct {
	Policy objectstorage.ObjectLifecyclePolicy
	ETag   *string
}

// refs:
//
//	https://docs.oracle.com/en-us/iaas/tools/go-sdk-examples/65.36.1/objectstorage/GetObjectLifecyclePolicy.go.html
//
//export OCIClientGetObjectLifecyclePolicy
func OCIClientGetObjectLifecyclePolicy(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	req := GetRequest[objectstorage.GetObjectLifecyclePolicyRequest](json_ptr)
	clientInfo := globalState.Get(cid)
	resp, err := clientInfo.client.GetObjectLifecyclePolicy(context.Background(), req)
	if should_retry(err) {
		log.Info("retrying lifecycle")
		resp, err = clientInfo.client.GetObjectLifecyclePolicy(context.Background(), req)
	}
	if err != nil {
		log.WithField("error", err).Info("GetLifecycle error")
	}
	my_resp := GetObjectLifecyclePolicyResponse{
		Policy: resp.ObjectLifecyclePolicy,
		ETag:   resp.ETag,
	}
	return ReturnResult(my_resp, err)
}

type ListBucketsResponse struct {
	Items       []objectstorage.BucketSummary
	OpcNextPage *string
}

//export OCIClientListBuckets
func OCIClientListBuckets(cid C.uint, json_ptr *C.char) (*C.char, C.longlong) {
	req := GetRequest[objectstorage.ListBucketsRequest](json_ptr)
	clientInfo := globalState.Get(cid)
	resp, err := clientInfo.client.ListBuckets(context.Background(), req)
	if should_retry(err) {
		log.Info("retrying listbuckets")
		resp, err = clientInfo.client.ListBuckets(context.Background(), req)
	}
	if err != nil {
		log.WithField("error", err).Info("ListBuckets error")
	}
	my_resp := ListBucketsResponse{
		Items:       resp.Items,
		OpcNextPage: resp.OpcNextPage,
	}
	return ReturnResult(my_resp, err)
}

//export OCITakeRateLimitErrors
func OCITakeRateLimitErrors(cid C.uint) C.ulong {
	clientInfo := globalState.Get(cid)
	return C.ulong(clientInfo.rate_limit_errors.Swap(0))
}

func main() {} // reqired for main package
