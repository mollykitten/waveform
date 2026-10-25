package scdrm

import (
	"bytes"
	"errors"
	"fmt"
	"math"

	"github.com/Eyevinn/mp4ff/mp4"
	"github.com/braheezy/shine-mp3/pkg/mp3"
	"github.com/skrashevich/go-aac/pkg/decoder"
)

// TranscodeM4AToMP3 converts an AAC/M4A buffer to MP3 without invoking external
// programs. The input must be a fragmented MP4/fMP4 with an mp4a audio track.
func TranscodeM4AToMP3(input []byte) ([]byte, error) {
	if len(input) == 0 {
		return nil, errors.New("empty m4a input")
	}
	asc, frames, err := extractAACFramesFromM4A(input)
	if err != nil {
		return nil, err
	}

	dec := decoder.New()
	if err := dec.SetASC(asc); err != nil {
		return nil, fmt.Errorf("initialize AAC decoder: %w", err)
	}

	var pcm []int16
	for i, frame := range frames {
		samples, err := dec.DecodeFrame(frame)
		if err != nil {
			return nil, fmt.Errorf("decode AAC frame %d: %w", i, err)
		}
		pcm = append(pcm, float32ToInt16(samples)...)
	}
	if len(pcm) == 0 {
		return nil, errors.New("AAC decoder returned no PCM samples")
	}

	channels := channelConfigToCount(dec.Config.ChanConfig)
	enc := mp3.NewEncoder(dec.Config.SampleRate, channels)

	// Force 320 kbps (MPEG-1 Layer III supports 320 kbps at index 14)
	// Only apply if it's MPEG-1 (Sample rate >= 32000)
	if dec.Config.SampleRate >= 32000 {
		enc.Mpeg.Bitrate = 320
		enc.Mpeg.BitrateIndex = 14
		
		// Recalculate frame slots based on shine-mp3's internal formulas
		// GRANULE_SIZE is 576 for MP3
		granulesPerFrame := float64(enc.Mpeg.GranulesPerFrame)
		avgSlotsPerFrame := (granulesPerFrame * 576.0 / float64(enc.Wave.SampleRate)) * (float64(enc.Mpeg.Bitrate) * 1000.0 / float64(enc.Mpeg.BitsPerSlot))
		enc.Mpeg.WholeSlotsPerFrame = int64(avgSlotsPerFrame)
		enc.Mpeg.FracSlotsPerFrame = avgSlotsPerFrame - float64(enc.Mpeg.WholeSlotsPerFrame)
		enc.Mpeg.Slot_lag = -enc.Mpeg.FracSlotsPerFrame
		if enc.Mpeg.FracSlotsPerFrame == 0 {
			enc.Mpeg.Padding = 0
		}
	}

	var out bytes.Buffer
	if err := enc.Write(&out, pcm); err != nil {
		return nil, fmt.Errorf("encode MP3: %w", err)
	}
	if out.Len() == 0 {
		return nil, errors.New("MP3 encoder returned empty output")
	}
	return out.Bytes(), nil
}

func extractAACFramesFromM4A(input []byte) ([]byte, [][]byte, error) {
	file, err := mp4.DecodeFile(bytes.NewReader(input))
	if err != nil {
		return nil, nil, fmt.Errorf("decode m4a container: %w", err)
	}
	if file.Init == nil || file.Init.Moov == nil {
		return nil, nil, errors.New("m4a does not contain an MP4 init segment")
	}

	audioTrak := findAACTrack(file.Init.Moov.Traks)
	if audioTrak == nil {
		return nil, nil, errors.New("m4a does not contain an AAC mp4a track")
	}
	esds := audioTrak.Mdia.Minf.Stbl.Stsd.Mp4a.Esds
	if esds == nil || esds.DecConfigDescriptor == nil || esds.DecConfigDescriptor.DecSpecificInfo == nil {
		return nil, nil, errors.New("AAC AudioSpecificConfig is missing")
	}
	asc := append([]byte(nil), esds.DecConfigDescriptor.DecSpecificInfo.DecConfig...)

	trex, ok := file.Init.Moov.Mvex.GetTrex(audioTrak.Tkhd.TrackID)
	if !ok {
		return nil, nil, fmt.Errorf("missing trex for audio track %d", audioTrak.Tkhd.TrackID)
	}

	var frames [][]byte
	for _, seg := range file.Segments {
		for _, frag := range seg.Fragments {
			samples, err := frag.GetFullSamples(trex)
			if err != nil {
				return nil, nil, fmt.Errorf("extract AAC samples: %w", err)
			}
			for _, sample := range samples {
				if len(sample.Data) == 0 {
					continue
				}
				frames = append(frames, append([]byte(nil), sample.Data...))
			}
		}
	}
	if len(frames) == 0 {
		return nil, nil, errors.New("m4a contains no AAC samples")
	}
	return asc, frames, nil
}

func findAACTrack(tracks []*mp4.TrakBox) *mp4.TrakBox {
	for _, track := range tracks {
		if track.Mdia != nil && track.Mdia.Hdlr != nil && track.Mdia.Hdlr.HandlerType == "soun" {
			if track.Mdia.Minf != nil && track.Mdia.Minf.Stbl != nil && track.Mdia.Minf.Stbl.Stsd != nil && track.Mdia.Minf.Stbl.Stsd.Mp4a != nil {
				return track
			}
		}
	}
	return nil
}

func float32ToInt16(samples []float32) []int16 {
	out := make([]int16, len(samples))
	for i, s := range samples {
		v := s * 32767.0
		if v > 32767.0 {
			v = 32767.0
		} else if v < -32768.0 {
			v = -32768.0
		}
		out[i] = int16(math.Round(float64(v)))
	}
	return out
}

func channelConfigToCount(config int) int {
	switch config {
	case 1:
		return 1
	case 2:
		return 2
	case 3:
		return 3
	case 4:
		return 4
	case 5:
		return 5
	case 6:
		return 6
	case 7:
		return 8
	default:
		return 2
	}
}
