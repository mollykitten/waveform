package scdrm

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/iyear/gowidevine"
	"github.com/iyear/gowidevine/widevinepb"
)

// User-agent, под которым друг протестировал media-CDN и license-эндпоинт.
const drmUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

type streamInfo struct {
	URL              string `json:"url"`
	LicenseAuthToken string `json:"licenseAuthToken"`
}

func fetchStreamInfo(ctx context.Context, httpClient *http.Client, transcodingURL string, clientID string) (*streamInfo, error) {
	u, err := url.Parse(transcodingURL)
	if err != nil {
		return nil, err
	}
	q := u.Query()
	q.Set("client_id", clientID)
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, "GET", u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", drmUserAgent)

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("stream info returned %d: %s", resp.StatusCode, string(body))
	}

	var info streamInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return nil, fmt.Errorf("decode stream info: %w", err)
	}
	return &info, nil
}

type cbcsPlaylist struct {
	InitSegmentURI string
	SegmentURIs    []string
	KID            []byte
	PSSH           []byte
}

func parseCBCSPlaylist(m3u8Content string, baseURL string) (*cbcsPlaylist, error) {
	pl := &cbcsPlaylist{}
	lines := strings.Split(m3u8Content, "\n")

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		if strings.HasPrefix(line, "#EXT-X-KEY:") {
			uriStart := strings.Index(line, "URI=\"")
			if uriStart == -1 {
				continue
			}
			start := uriStart + 5
			end := strings.Index(line[start:], "\"")
			if end == -1 {
				continue
			}
			keyURI := line[start : start+end]

			// Widevine PSSH лежит инлайном в data-URI (ctr-encrypted-hls).
			if strings.HasPrefix(keyURI, "data:text/plain;base64,") || strings.HasPrefix(keyURI, "data:application/octet-stream;base64,") {
				pssh, err := extractPSSHFromDataURI(keyURI)
				if err == nil && widevinePSSHIsOurs(pssh) {
					if pl.PSSH == nil {
						pl.PSSH = pssh
					}
					if len(pl.KID) == 0 && len(pssh) >= 48 {
						pl.KID = pssh[32:48]
					}
				}
				continue
			}

			// skd:// — FairPlay (cbc-encrypted-hls), его не умеем.
			if kid, err := kidFromSKD(keyURI); err == nil {
				if len(pl.KID) == 0 {
					pl.KID = kid
				}
			}
		}

		if strings.HasPrefix(line, "#EXT-X-MAP:") {
			parts := strings.Split(line, "\"")
			if len(parts) >= 3 {
				pl.InitSegmentURI = resolveURI(parts[1], baseURL)
			}
		}

		if !strings.HasPrefix(line, "#") {
			pl.SegmentURIs = append(pl.SegmentURIs, resolveURI(line, baseURL))
		}
	}

	if len(pl.PSSH) == 0 && len(pl.KID) == 0 {
		return nil, fmt.Errorf("no Widevine PSSH found in playlist")
	}
	if pl.InitSegmentURI == "" {
		return nil, fmt.Errorf("no init segment found in playlist")
	}
	if len(pl.SegmentURIs) == 0 {
		return nil, fmt.Errorf("no segments found in playlist")
	}

	return pl, nil
}

// widevinePSSHIsOurs проверяет, что PSSH-box с SystemID Widevine
// (edef8ba9-79d6-4ace-a3c8-27dcd51d21ed), а не PlayReady из соседней
// #EXT-X-KEY строки.
func widevinePSSHIsOurs(pssh []byte) bool {
	if len(pssh) < 28 {
		return false
	}
	// box: [size 4][type 'pssh'][version+flags 4][systemID 16]
	if string(pssh[4:8]) != "pssh" {
		return false
	}
	want, _ := hex.DecodeString("edef8ba979d64acea3c827dcd51d21ed")
	return bytes.Equal(pssh[12:28], want)
}

func resolveURI(uri string, baseURL string) string {
	if strings.HasPrefix(uri, "http://") || strings.HasPrefix(uri, "https://") {
		return uri
	}
	base, err := url.Parse(baseURL)
	if err != nil {
		return uri
	}
	rel, err := url.Parse(uri)
	if err != nil {
		return uri
	}
	return base.ResolveReference(rel).String()
}

func downloadCBCSSegments(ctx context.Context, httpClient *http.Client, pl *cbcsPlaylist) ([]byte, error) {
	initData, err := downloadFile(ctx, httpClient, pl.InitSegmentURI)
	if err != nil {
		return nil, fmt.Errorf("download init segment: %w", err)
	}

	var segmentsBuf bytes.Buffer
	segmentsBuf.Write(initData)

	for _, segURI := range pl.SegmentURIs {
		data, err := downloadFile(ctx, httpClient, segURI)
		if err != nil {
			return nil, fmt.Errorf("download segment %s: %w", segURI, err)
		}
		segmentsBuf.Write(data)
	}

	return segmentsBuf.Bytes(), nil
}

func downloadFile(ctx context.Context, httpClient *http.Client, urlStr string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", urlStr, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", drmUserAgent)

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("download %s returned %d", urlStr, resp.StatusCode)
	}

	return io.ReadAll(resp.Body)
}

func decryptCBCS(encrypted []byte, keys []*widevine.Key) ([]byte, error) {
	reader := bytes.NewReader(encrypted)
	var out bytes.Buffer

	if err := widevine.DecryptMP4Auto(reader, keys, &out); err != nil {
		return nil, fmt.Errorf("CBCS decryption failed: %w", err)
	}

	return out.Bytes(), nil
}

// extractPSSHFromDataURI декодирует base64 PSSH-box из data:...;base64,... URI.
func extractPSSHFromDataURI(uri string) ([]byte, error) {
	if !strings.HasPrefix(uri, "data:text/plain;base64,") && !strings.HasPrefix(uri, "data:application/octet-stream;base64,") {
		return nil, fmt.Errorf("unsupported data URI format")
	}
	commaIdx := strings.Index(uri, ",")
	if commaIdx == -1 {
		return nil, fmt.Errorf("no comma in data URI")
	}
	b64 := uri[commaIdx+1:]
	return base64.StdEncoding.DecodeString(b64)
}

func kidFromSKD(skdURI string) ([]byte, error) {
	if len(skdURI) < 6 || skdURI[:6] != "skd://" {
		return nil, fmt.Errorf("invalid skd URI: %s", skdURI)
	}
	kidStr := skdURI[6:]
	kidStr = stripHyphens(kidStr)
	if len(kidStr) < 32 {
		return nil, fmt.Errorf("KID too short in skd URI: %s", skdURI)
	}
	return hex.DecodeString(kidStr[:32])
}

func stripHyphens(s string) string {
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] != '-' {
			b = append(b, s[i])
		}
	}
	return string(b)
}

func buildPSSHFromKID(kid []byte) []byte {
	pssh := []byte{
		0x00, 0x00, 0x00, 0x32,
		0x70, 0x73, 0x73, 0x68,
		0x00, 0x00, 0x00, 0x00,
		0xed, 0xef, 0x8b, 0xa9, 0x79, 0xd6, 0x4a, 0xce,
		0xa3, 0xc8, 0x27, 0xdc, 0xd5, 0x1d, 0x21, 0xed,
		0x00, 0x00, 0x00, 0x12,
		0x12, 0x10,
	}
	return append(pssh, kid...)
}

func getLicenseKeys(ctx context.Context, httpClient *http.Client, deviceWVD []byte, psshBytes []byte, licenseURL string, licenseAuthToken string) ([]*widevine.Key, error) {
	device, err := widevine.NewDevice(widevine.FromWVD(bytes.NewReader(deviceWVD)))
	if err != nil {
		return nil, fmt.Errorf("load device: %w", err)
	}

	cdm := widevine.NewCDM(device)

	pssh, err := widevine.NewPSSH(psshBytes)
	if err != nil {
		return nil, fmt.Errorf("parse PSSH: %w", err)
	}

	challenge, parseFunc, err := cdm.GetLicenseChallenge(pssh, widevinepb.LicenseType_STREAMING, false)
	if err != nil {
		return nil, fmt.Errorf("license challenge: %w", err)
	}

	u, err := url.Parse(licenseURL)
	if err != nil {
		return nil, fmt.Errorf("parse license URL: %w", err)
	}
	q := u.Query()
	q.Set("license_token", licenseAuthToken)
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, "POST", u.String(), bytes.NewReader(challenge))
	if err != nil {
		return nil, err
	}

	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Origin", "https://soundcloud.com")
	req.Header.Set("Referer", "https://soundcloud.com/")
	req.Header.Set("User-Agent", drmUserAgent)

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("license server returned %d: %s", resp.StatusCode, string(body))
	}

	licenseBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read license response: %w", err)
	}

	keys, err := parseFunc(licenseBytes)
	if err != nil {
		return nil, fmt.Errorf("parse license: %w", err)
	}

	return keys, nil
}
