#ifndef APP_LAME_H
#define APP_LAME_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Encodes interleaved Float32 PCM (each sample in [-1, 1]) to a raw CBR MP3
 * frame stream — no ID3 tag, no VBR/Xing header frame, just audio frames, so
 * the output can be treated the same way as ParsoAudioCore's Glint encoder
 * output (callers that want an ID3 header prepend it themselves).
 *
 * Returns a malloc'd buffer the caller must free with app_lame_free(), or
 * NULL on failure (invalid parameters, or LAME itself rejecting the
 * requested bitrate/sample-rate/channel combination).
 */
uint8_t *app_lame_encode(const float *interleaved_pcm,
                          int32_t frame_count,
                          int32_t channel_count,
                          int32_t sample_rate,
                          int32_t bitrate_kbps,
                          int32_t *out_size);

void app_lame_free(uint8_t *buffer);

#ifdef __cplusplus
}
#endif
#endif
