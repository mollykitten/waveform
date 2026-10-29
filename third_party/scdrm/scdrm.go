package scdrm

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"time"
)

// DefaultWidevineLicenseURL — прод-эндпоинт SoundCloud для Widevine-лицензий.
const DefaultWidevineLicenseURL = "https://license.media-streaming.soundcloud.cloud/playback/widevine"

// DecryptTrack расшифровывает ctr-encrypted-hls (CENC/Widevine) трек целиком
// в память и пишет результат в outPath. Вход — transcoding URL из
// media.transcodings[] api-v2 (в нём уже сидит track_authorization).
// Формат выхода — расшифрованный M4A (AAC без пересжатия).
//
// httpClient может быть nil — тогда используется обычный net/http без куки.
func DecryptTrack(ctx context.Context, httpClient *http.Client, transcodingURL, clientID, wvdPath, outPath, licenseURL string) (string, error) {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 2 * time.Minute}
	}
	if licenseURL == "" {
		licenseURL = DefaultWidevineLicenseURL
	}

	wvd, err := os.ReadFile(wvdPath)
	if err != nil {
		return "", fmt.Errorf("read wvd: %w", err)
	}

	info, err := fetchStreamInfo(ctx, httpClient, transcodingURL, clientID)
	if err != nil {
		return "", fmt.Errorf("fetch stream info: %w", err)
	}

	playlistData, err := downloadFile(ctx, httpClient, info.URL)
	if err != nil {
		return "", fmt.Errorf("download playlist: %w", err)
	}

	pl, err := parseCBCSPlaylist(string(playlistData), info.URL)
	if err != nil {
		return "", fmt.Errorf("parse playlist: %w", err)
	}

	psshData := pl.PSSH
	if len(psshData) == 0 {
		psshData = buildPSSHFromKID(pl.KID)
	}

	keys, err := getLicenseKeys(ctx, httpClient, wvd, psshData, licenseURL, info.LicenseAuthToken)
	if err != nil {
		return "", fmt.Errorf("license keys: %w", err)
	}

	encrypted, err := downloadCBCSSegments(ctx, httpClient, pl)
	if err != nil {
		return "", fmt.Errorf("download segments: %w", err)
	}

	decrypted, err := decryptCBCS(encrypted, keys)
	if err != nil {
		return "", fmt.Errorf("decrypt: %w", err)
	}

	// Отдаём расшифрованный AAC как есть. Транскод в MP3 (TranscodeM4AToMP3)
	// не используем: чисто-Go декодер go-aac местами отдаёт NaN и выбросы
	// амплитуды, из-за чего в звуке трески; AVFoundation/just_audio играют
	// fMP4 напрямую без потерь.
	format := "m4a"
	out := decrypted

	tmp := outPath + ".tmp"
	if err := os.WriteFile(tmp, out, 0644); err != nil {
		return "", fmt.Errorf("write output: %w", err)
	}
	if err := os.Rename(tmp, outPath); err != nil {
		return "", fmt.Errorf("rename output: %w", err)
	}

	return format, nil
}
