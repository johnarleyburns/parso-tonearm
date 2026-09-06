#include "app_lame.h"
#include "lame.h"
#include <stdlib.h>

uint8_t *app_lame_encode(const float *interleaved_pcm, int32_t frame_count,
                          int32_t channel_count, int32_t sample_rate,
                          int32_t bitrate_kbps, int32_t *out_size) {
    if (out_size == NULL) return NULL;
    *out_size = 0;
    if (interleaved_pcm == NULL || frame_count <= 0 ||
        (channel_count != 1 && channel_count != 2) ||
        sample_rate <= 0 || bitrate_kbps <= 0) {
        return NULL;
    }

    lame_global_flags *gfp = lame_init();
    if (gfp == NULL) return NULL;

    lame_set_num_channels(gfp, channel_count);
    lame_set_in_samplerate(gfp, sample_rate);
    lame_set_brate(gfp, bitrate_kbps);
    lame_set_VBR(gfp, vbr_off);
    /* No Xing/LAME info frame — the output must be a plain run of uniform
     * CBR frames, matching Glint's contract (no header/tag frame either). */
    lame_set_bWriteVbrTag(gfp, 0);
    /* 2 = "high quality, close to psycho-acoustic optimum" per lame.h; the
     * best tradeoff of encode speed vs quality for an on-device encode. */
    lame_set_quality(gfp, 2);

    if (lame_init_params(gfp) < 0) {
        lame_close(gfp);
        return NULL;
    }

    /* LAME's own sizing guidance (lame.h, lame_encode_buffer doc comment):
     * 1.25 * num_samples + 7200 bytes is guaranteed sufficient headroom. */
    int32_t mp3_capacity = (int32_t)(1.25 * (double)frame_count) + 7200;
    uint8_t *mp3_buf = (uint8_t *)malloc((size_t)mp3_capacity);
    if (mp3_buf == NULL) {
        lame_close(gfp);
        return NULL;
    }

    int written;
    if (channel_count == 1) {
        /* LAME's mono ieee_float entry takes the same channel buffer twice. */
        written = lame_encode_buffer_ieee_float(gfp, interleaved_pcm, interleaved_pcm,
                                                 frame_count, mp3_buf, mp3_capacity);
    } else {
        written = lame_encode_buffer_interleaved_ieee_float(
            gfp, interleaved_pcm, frame_count, mp3_buf, mp3_capacity);
    }

    if (written >= 0) {
        int flush = lame_encode_flush(gfp, mp3_buf + written, mp3_capacity - written);
        if (flush >= 0) {
            written += flush;
        } else {
            written = flush;
        }
    }

    lame_close(gfp);

    if (written < 0) {
        free(mp3_buf);
        return NULL;
    }

    *out_size = written;
    return mp3_buf;
}

void app_lame_free(uint8_t *buffer) {
    free(buffer);
}
