/*
 * sie.h — C ABI for libsie-z (SIE file reader, Zig port).
 *
 * All handles are opaque pointers. Functions returning `int` return 0
 * (`SIE_OK`) on success, or a non-zero status code (see SIE_E_*).
 * Strings are returned as (ptr, len) pairs and are NOT NUL-terminated;
 * tag values may contain embedded NULs.
 *
 * Memory ownership:
 *   - `*_open`, `*_attach`, `*_new`, `*_from_*` create handles you must
 *     release with the matching `*_close` / `*_free` function.
 *   - Accessor handles (channels, tests, tags, dims, outputs) are borrowed
 *     and remain valid until the owning object is freed.
 *   - An Output returned from `sie_spigot_get` is invalidated by the next
 *     call to `sie_spigot_get` on the same spigot.
 */
#ifndef LIBSIE_SIE_H
#define LIBSIE_SIE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Status codes ──────────────────────────────────────────────────────── */
#define SIE_OK                       0
#define SIE_E_FILE_NOT_FOUND         1
#define SIE_E_PERMISSION_DENIED      2
#define SIE_E_FILE_OPEN              3
#define SIE_E_FILE_READ              4
#define SIE_E_FILE_WRITE             5
#define SIE_E_FILE_SEEK              6
#define SIE_E_FILE_TRUNCATED         7
#define SIE_E_INVALID_FORMAT        10
#define SIE_E_INVALID_BLOCK         11
#define SIE_E_UNEXPECTED_EOF        12
#define SIE_E_CORRUPTED_DATA        13
#define SIE_E_INVALID_XML           20
#define SIE_E_INVALID_EXPRESSION    21
#define SIE_E_PARSE                 22
#define SIE_E_OUT_OF_MEMORY         30
#define SIE_E_INVALID_DATA          40
#define SIE_E_DIMENSION_MISMATCH    41
#define SIE_E_INDEX_OUT_OF_BOUNDS   42
#define SIE_E_NOT_IMPLEMENTED       50
#define SIE_E_OPERATION_FAILED      51
#define SIE_E_STREAM_ENDED          52
#define SIE_E_UNKNOWN               99

/* Output dimension types (returned by sie_output_type). */
#define SIE_OUTPUT_NONE      0
#define SIE_OUTPUT_FLOAT64   1
#define SIE_OUTPUT_RAW       2

/* ── Opaque handles ────────────────────────────────────────────────────── */
typedef struct sie_File      sie_File;
typedef struct sie_Channel   sie_Channel;
typedef struct sie_Test      sie_Test;
typedef struct sie_Tag       sie_Tag;
typedef struct sie_Dimension sie_Dimension;
typedef struct sie_Spigot    sie_Spigot;
typedef struct sie_Output    sie_Output;
typedef struct sie_Stream    sie_Stream;
typedef struct sie_Histogram sie_Histogram;
typedef struct sie_Writer      sie_Writer;
typedef struct sie_FileStream  sie_FileStream;
typedef struct sie_PlotCrusher sie_PlotCrusher;
typedef struct sie_Sifter      sie_Sifter;

/* Writer ID classes (for sie_writer_next_id). */
#define SIE_WRITER_ID_GROUP    0
#define SIE_WRITER_ID_TEST     1
#define SIE_WRITER_ID_CHANNEL  2
#define SIE_WRITER_ID_DECODER  3

/* Writer callback. The writer invokes this once per fully-formed block
 * (header + payload + trailer). Must return the number of bytes consumed;
 * any short return is treated as SIE_E_FILE_WRITE. */
typedef size_t (*sie_writer_fn)(void *user, const uint8_t *data, size_t size);

/* ── Library info ──────────────────────────────────────────────────────── */
const char *sie_version(void);
const char *sie_status_message(int status);

/* ── SieFile ───────────────────────────────────────────────────────────── */
int      sie_file_open(const char *path, sie_File **out_handle);
void     sie_file_close(sie_File *handle);

size_t   sie_file_num_channels(sie_File *handle);
size_t   sie_file_num_tests(sie_File *handle);
size_t   sie_file_num_tags(sie_File *handle);

sie_Channel   *sie_file_channel(sie_File *handle, size_t index);
sie_Test      *sie_file_test(sie_File *handle, size_t index);
const sie_Tag *sie_file_tag(sie_File *handle, size_t index);

sie_Channel *sie_file_find_channel(sie_File *handle, uint32_t id);
sie_Test    *sie_file_find_test(sie_File *handle, uint32_t id);
sie_Test    *sie_file_containing_test(sie_File *handle, sie_Channel *ch);

/* ── Test ──────────────────────────────────────────────────────────────── */
uint32_t       sie_test_id(sie_Test *handle);
void           sie_test_name(sie_Test *handle, const char **out_ptr, size_t *out_len);
size_t         sie_test_num_channels(sie_Test *handle);
sie_Channel   *sie_test_channel(sie_Test *handle, size_t index);
size_t         sie_test_num_tags(sie_Test *handle);
const sie_Tag *sie_test_tag(sie_Test *handle, size_t index);
const sie_Tag *sie_test_find_tag(sie_Test *handle, const char *key);

/* ── Channel ───────────────────────────────────────────────────────────── */
uint32_t              sie_channel_id(sie_Channel *handle);
uint32_t              sie_channel_test_id(sie_Channel *handle);
void                  sie_channel_name(sie_Channel *handle, const char **out_ptr, size_t *out_len);
size_t                sie_channel_num_dims(sie_Channel *handle);
const sie_Dimension  *sie_channel_dimension(sie_Channel *handle, size_t index);
size_t                sie_channel_num_tags(sie_Channel *handle);
const sie_Tag        *sie_channel_tag(sie_Channel *handle, size_t index);
const sie_Tag        *sie_channel_find_tag(sie_Channel *handle, const char *key);

/* ── Dimension ─────────────────────────────────────────────────────────── */
uint32_t       sie_dimension_index(const sie_Dimension *handle);
void           sie_dimension_name(const sie_Dimension *handle, const char **out_ptr, size_t *out_len);
size_t         sie_dimension_num_tags(const sie_Dimension *handle);
const sie_Tag *sie_dimension_tag(const sie_Dimension *handle, size_t index);
const sie_Tag *sie_dimension_find_tag(const sie_Dimension *handle, const char *key);

/* ── Tag ───────────────────────────────────────────────────────────────── */
void     sie_tag_key(const sie_Tag *handle, const char **out_ptr, size_t *out_len);
void     sie_tag_value(const sie_Tag *handle, const char **out_ptr, size_t *out_len);
size_t   sie_tag_value_size(const sie_Tag *handle);
int      sie_tag_is_string(const sie_Tag *handle);
int      sie_tag_is_binary(const sie_Tag *handle);
uint32_t sie_tag_group(const sie_Tag *handle);
int      sie_tag_is_from_group(const sie_Tag *handle);

/* ── Spigot ────────────────────────────────────────────────────────────── */
int      sie_spigot_attach(sie_File *file, sie_Channel *channel, sie_Spigot **out);
void     sie_spigot_free(sie_Spigot *handle);

/* On exhaustion, *out_output is set to NULL and SIE_OK is returned. */
int      sie_spigot_get(sie_Spigot *handle, sie_Output **out_output);

uint64_t sie_spigot_tell(sie_Spigot *handle);
uint64_t sie_spigot_seek(sie_Spigot *handle, uint64_t target);
void     sie_spigot_reset(sie_Spigot *handle);
int      sie_spigot_is_done(sie_Spigot *handle);
size_t   sie_spigot_num_blocks(sie_Spigot *handle);

void     sie_spigot_disable_transforms(sie_Spigot *handle, int disable);
int      sie_spigot_transform_output(sie_Spigot *handle, sie_Output *output);
void     sie_spigot_set_scan_limit(sie_Spigot *handle, uint64_t limit);
void     sie_spigot_clear_output(sie_Spigot *handle);

int      sie_spigot_lower_bound(sie_Spigot *handle, size_t dim, double value,
                                uint64_t *out_block, uint64_t *out_scan, int *out_found);
int      sie_spigot_upper_bound(sie_Spigot *handle, size_t dim, double value,
                                uint64_t *out_block, uint64_t *out_scan, int *out_found);

/* ── Output (borrowed from spigot) ─────────────────────────────────────── */
size_t   sie_output_num_dims(sie_Output *handle);
size_t   sie_output_num_rows(sie_Output *handle);
size_t   sie_output_block(sie_Output *handle);
int      sie_output_type(sie_Output *handle, size_t dim);
int      sie_output_get_float64(sie_Output *handle, size_t dim, size_t row, double *out_value);
int      sie_output_get_raw(sie_Output *handle, size_t dim, size_t row,
                            const uint8_t **out_ptr, uint32_t *out_size);

/* Bulk variants — copy `count` consecutive rows of dim `dim` starting at
 * `start_row`. `*out_written` receives the number of rows actually
 * written (may be less than `count` at end of block). One call replaces
 * `count` per-sample calls to `sie_output_get_float64` /
 * `sie_output_get_raw`, eliminating per-sample FFI overhead for callers
 * that read whole channels (e.g. Julia `read!`). For the raw variant
 * the output rows' borrowed pointers remain valid until the next
 * `sie_spigot_get` on the owning spigot. */
int      sie_output_get_float64_range(sie_Output *handle, size_t dim,
                                      size_t start_row, size_t count,
                                      double *out_buf, size_t *out_written);
int      sie_output_get_raw_range(sie_Output *handle, size_t dim,
                                  size_t start_row, size_t count,
                                  const uint8_t **out_ptrs, uint32_t *out_sizes,
                                  size_t *out_written);

/* ── Stream (incremental ingest) ───────────────────────────────────────── */
int      sie_stream_new(sie_Stream **out_handle);
void     sie_stream_free(sie_Stream *handle);
int      sie_stream_add_data(sie_Stream *handle, const uint8_t *data, size_t size,
                             size_t *out_consumed);
uint32_t sie_stream_num_groups(sie_Stream *handle);
size_t   sie_stream_group_num_blocks(sie_Stream *handle, uint32_t group_id);
uint64_t sie_stream_group_num_bytes(sie_Stream *handle, uint32_t group_id);
int      sie_stream_is_group_closed(sie_Stream *handle, uint32_t group_id);

/* ── Histogram ─────────────────────────────────────────────────────────── */
int      sie_histogram_from_channel(sie_File *file, sie_Channel *channel,
                                    sie_Histogram **out_handle);
void     sie_histogram_free(sie_Histogram *handle);
size_t   sie_histogram_num_dims(sie_Histogram *handle);
size_t   sie_histogram_total_size(sie_Histogram *handle);
size_t   sie_histogram_num_bins(sie_Histogram *handle, size_t dim);
int      sie_histogram_get_bin(sie_Histogram *handle, const size_t *indices, double *out_value);
int      sie_histogram_get_bounds(sie_Histogram *handle, size_t dim,
                                  double *lower, double *upper, size_t capacity);

/* ── Writer (low-level block writer) ───────────────────────────────────── */
/* Compose SIE blocks in memory and emit each one through `callback`.
 * Use `callback = NULL` for a dry-run writer that only tracks offsets,
 * IDs, and index entries. */
int      sie_writer_new(sie_writer_fn callback, void *user, sie_Writer **out_handle);
void     sie_writer_free(sie_Writer *handle);
int      sie_writer_write_block(sie_Writer *handle, uint32_t group,
                                const uint8_t *data, size_t size);
int      sie_writer_xml_string(sie_Writer *handle, const uint8_t *data, size_t size);
int      sie_writer_xml_header(sie_Writer *handle);
void     sie_writer_flush_xml(sie_Writer *handle);
void     sie_writer_flush_index(sie_Writer *handle);
uint32_t sie_writer_next_id(sie_Writer *handle, int id_type);
uint64_t sie_writer_total_size(sie_Writer *handle, uint64_t addl_bytes,
                               uint64_t addl_blocks);
uint64_t sie_writer_offset(sie_Writer *handle);
void     sie_writer_set_do_index(sie_Writer *handle, int do_index);

/* ── FileStream (incremental write-to-file) ────────────────────────────── */
/* Feed raw SIE bytes incrementally; complete blocks are written through
 * to `path` and indexed by group. */
int      sie_file_stream_open(const char *path, sie_FileStream **out_handle);
void     sie_file_stream_close(sie_FileStream *handle);
int      sie_file_stream_add_data(sie_FileStream *handle,
                                  const uint8_t *data, size_t size,
                                  size_t *out_consumed);
int      sie_file_stream_is_group_closed(sie_FileStream *handle, uint32_t group);
uint32_t sie_file_stream_num_groups(sie_FileStream *handle);
uint32_t sie_file_stream_highest_group(sie_FileStream *handle);

/* ── Recover ───────────────────────────────────────────────────────────── */
/* Run 3-pass corruption recovery on `path`. `mod` is the alignment
 * modulus for glue-offset search (0 = any). On success writes a JSON
 * summary that the caller MUST free via `sie_string_free`. */
int      sie_recover(const char *path, uint64_t mod,
                     const uint8_t **out_json, size_t *out_len);
void     sie_string_free(const uint8_t *ptr, size_t len);

/* ── PlotCrusher (downsampling for plotting) ───────────────────────────── */
int      sie_plot_crusher_new(size_t ideal_scans, sie_PlotCrusher **out_handle);
void     sie_plot_crusher_free(sie_PlotCrusher *handle);
int      sie_plot_crusher_work(sie_PlotCrusher *handle, sie_Output *input,
                               int *out_done);
void     sie_plot_crusher_finalize(sie_PlotCrusher *handle);
/* Borrowed; valid until the next sie_plot_crusher_work or _free. */
sie_Output *sie_plot_crusher_get_output(sie_PlotCrusher *handle);

/* ── Sifter (subset extraction through a writer) ───────────────────────── */
/* The sifter borrows the writer; do not free the writer before the sifter. */
int      sie_sifter_new(sie_Writer *writer, sie_Sifter **out_handle);
void     sie_sifter_free(sie_Sifter *handle);
int      sie_sifter_add_channel(sie_Sifter *handle, sie_File *file,
                                sie_Channel *channel,
                                uint64_t start_block, uint64_t end_block);
int      sie_sifter_finish(sie_Sifter *handle, sie_File *file);
size_t   sie_sifter_total_entries(sie_Sifter *handle);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* LIBSIE_SIE_H */
