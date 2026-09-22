#ifndef CSTBVORBIS_H
#define CSTBVORBIS_H

/* Decode an entire Ogg Vorbis stream held in memory to interleaved 16-bit PCM.
   Returns the number of samples per channel (>=0), or a negative value on error.
   On success *output points to a malloc'd buffer of
   (returned_samples * channels) shorts; the caller must free() it. */
extern int stb_vorbis_decode_memory(const unsigned char *mem, int len,
                                    int *channels, int *sample_rate,
                                    short **output);

#endif
