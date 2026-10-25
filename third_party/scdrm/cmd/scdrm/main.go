package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"net/http"
	"time"
	"unsafe"

	"scdrm"
)

//export scdrm_version
func scdrm_version() *C.char {
	return C.CString("scdrm 0.1.0")
}

// scdrm_license_url возвращает прод-эндпоинт Widevine-лицензий
// (нужен live-самотесту из Dart без хардкода).
//
//export scdrm_license_url
func scdrm_license_url() *C.char {
	return C.CString(scdrm.DefaultWidevineLicenseURL)
}

// scdrm_decrypt — C API ядра. transcodingURL — URL ctr-encrypted-hls из
// media.transcodings[] (track_authorization уже внутри); clientID — свежий
// client_id api-v2; wvdPath/outPath — абсолютные пути файлов.
// Возвращает NULL при успехе либо строку ошибки (освободить через scdrm_free).
//
//export scdrm_decrypt
func scdrm_decrypt(transcodingURL *C.char, clientID *C.char, wvdPath *C.char, outPath *C.char, licenseURL *C.char) *C.char {
	if transcodingURL == nil || clientID == nil || wvdPath == nil || outPath == nil {
		return C.CString("scdrm: nil argument")
	}
	lURL := ""
	if licenseURL != nil {
		lURL = C.GoString(licenseURL)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	_, err := scdrm.DecryptTrack(ctx, &http.Client{},
		C.GoString(transcodingURL), C.GoString(clientID),
		C.GoString(wvdPath), C.GoString(outPath), lURL)
	if err != nil {
		return C.CString(err.Error())
	}
	return nil
}

// scdrm_free освобождает строку ошибки, возвращённую scdrm_decrypt.
//
//export scdrm_free
func scdrm_free(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
