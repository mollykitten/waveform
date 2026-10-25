package scdrm

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"net/http"
	"testing"
	"time"
)

func TestPlaylistAcceptsWidevinePSSH(t *testing.T) {
	pssh := buildPSSHFromKID(make([]byte, 16))
	playlist := "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI=\"data:text/plain;base64," + base64.StdEncoding.EncodeToString(pssh) + "\"\n#EXT-X-MAP:URI=\"init.mp4\"\nsegment.m4s\n"
	pl, err := parseCBCSPlaylist(playlist, "https://example.invalid/audio/playlist.m3u8")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(pl.PSSH, pssh) {
		t.Fatal("playlist lost Widevine PSSH")
	}
}

func TestWidevinePSSHRejectsInvalidBoxes(t *testing.T) {
	pssh := buildPSSHFromKID(make([]byte, 16))
	for n := 0; n < 28; n++ {
		if widevinePSSHIsOurs(pssh[:n]) {
			t.Fatalf("accepted truncated box of %d bytes", n)
		}
	}
	pssh[12] ^= 1
	if widevinePSSHIsOurs(pssh) {
		t.Fatal("accepted another SystemID")
	}
	pssh[12] ^= 1
	copy(pssh[4:8], "free")
	if widevinePSSHIsOurs(pssh) {
		t.Fatal("accepted another box type")
	}
}

type licenseTransport func(*http.Request) (*http.Response, error)

func (f licenseTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Generate an unsigned, synthetic device in memory; no service credentials.
func syntheticWVD(t *testing.T) []byte {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der := x509.MarshalPKCS1PrivateKey(key)
	var b bytes.Buffer
	b.Write([]byte{'W', 'V', 'D', 2, 2, 3, 0})
	if err := binary.Write(&b, binary.BigEndian, uint16(len(der))); err != nil {
		t.Fatal(err)
	}
	b.Write(der)
	b.Write([]byte{0, 0}) // empty protobuf ClientIdentification
	return b.Bytes()
}

func TestLicenseRequestCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	client := &http.Client{Transport: licenseTransport(func(r *http.Request) (*http.Response, error) {
		cancel()
		select {
		case <-r.Context().Done():
			return nil, r.Context().Err()
		case <-time.After(time.Second):
			return nil, errors.New("license request ignored cancellation")
		}
	})}
	_, err := getLicenseKeys(ctx, client, syntheticWVD(t), buildPSSHFromKID(make([]byte, 16)), "https://example.invalid/license", "synthetic")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got %v", err)
	}
}
