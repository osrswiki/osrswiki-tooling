/*
 * Exact row-streaming source accounting for the non-surface realm pipeline.
 *
 * Build:
 *   cc -std=c11 -O2 -Wall -Wextra -Werror \
 *     $(pkg-config --cflags libpng) osrs_source_accounting.c \
 *     $(pkg-config --libs libpng) -o osrs_source_accounting
 *
 * The source contract is deliberately strict: 8-bit RGB and a same-sized
 * 16-bit grayscale owner-code PNG.  Code zero means unowned.  Only RGB 0,0,0
 * is no-data; every other source pixel requires a nonzero provenance code.
 */

#include <errno.h>
#include <inttypes.h>
#include <png.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OSRS_OWNER_CODE_COUNT 65536u

typedef struct
{
	FILE *file;
	png_structp png;
	png_infop info;
	png_uint_32 width;
	png_uint_32 height;
	int bit_depth;
	int color_type;
	size_t row_bytes;
} osrsPngReader;

static void osrsUsage(const char *program)
{
	fprintf(stderr,
		"usage: %s --source SOURCE_RGB.png --owners OWNER_UINT16.png "
		"--output ACCOUNTING.json [--require-zero]\n",
		program);
}

static void osrsCloseReader(osrsPngReader *reader)
{
	if (reader->png != NULL || reader->info != NULL)
	{
		png_destroy_read_struct(&reader->png, &reader->info, NULL);
	}
	if (reader->file != NULL)
	{
		fclose(reader->file);
	}
	memset(reader, 0, sizeof(*reader));
}

static bool osrsOpenReader(const char *path, osrsPngReader *reader)
{
	unsigned char signature[8];
	memset(reader, 0, sizeof(*reader));
	reader->file = fopen(path, "rb");
	if (reader->file == NULL)
	{
		fprintf(stderr, "cannot open %s: %s\n", path, strerror(errno));
		return false;
	}
	if (fread(signature, 1, sizeof(signature), reader->file) != sizeof(signature) ||
		png_sig_cmp(signature, 0, sizeof(signature)) != 0)
	{
		fprintf(stderr, "%s is not a PNG file\n", path);
		osrsCloseReader(reader);
		return false;
	}
	reader->png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
	reader->info = reader->png == NULL ? NULL : png_create_info_struct(reader->png);
	if (reader->png == NULL || reader->info == NULL)
	{
		fprintf(stderr, "libpng allocation failed for %s\n", path);
		osrsCloseReader(reader);
		return false;
	}
	if (setjmp(png_jmpbuf(reader->png)) != 0)
	{
		fprintf(stderr, "libpng header read failed for %s\n", path);
		osrsCloseReader(reader);
		return false;
	}
	png_init_io(reader->png, reader->file);
	png_set_sig_bytes(reader->png, sizeof(signature));
	png_read_info(reader->png, reader->info);
	reader->width = png_get_image_width(reader->png, reader->info);
	reader->height = png_get_image_height(reader->png, reader->info);
	reader->bit_depth = png_get_bit_depth(reader->png, reader->info);
	reader->color_type = png_get_color_type(reader->png, reader->info);
	png_read_update_info(reader->png, reader->info);
	reader->row_bytes = png_get_rowbytes(reader->png, reader->info);
	return true;
}

static uint16_t osrsReadBigEndianU16(const png_bytep bytes)
{
	return (uint16_t) (((uint16_t) bytes[0] << 8u) | bytes[1]);
}

static bool osrsWriteJson(
	const char *path,
	png_uint_32 width,
	png_uint_32 height,
	uint64_t source_pixels,
	uint64_t content_pixels,
	uint64_t black_pixels,
	uint64_t unresolved_pixels,
	uint64_t background_pixels,
	uint64_t owned_black_pixels,
	const uint64_t *owner_total,
	const uint64_t *owner_content,
	const uint32_t *owner_min_x,
	const uint32_t *owner_min_y,
	const uint32_t *owner_max_x,
	const uint32_t *owner_max_y)
{
	FILE *output = fopen(path, "wb");
	if (output == NULL)
	{
		fprintf(stderr, "cannot create %s: %s\n", path, strerror(errno));
		return false;
	}
	fprintf(output,
		"{\n"
		"  \"schema_version\": 1,\n"
		"  \"width\": %u,\n"
		"  \"height\": %u,\n"
		"  \"source_pixels\": %" PRIu64 ",\n"
		"  \"content_bearing_pixels\": %" PRIu64 ",\n"
		"  \"exact_black_pixels\": %" PRIu64 ",\n"
		"  \"unresolved_content_bearing_pixels\": %" PRIu64 ",\n"
		"  \"legitimate_unowned_exact_black_pixels\": %" PRIu64 ",\n"
		"  \"owned_exact_black_pixels\": %" PRIu64 ",\n"
		"  \"background_predicate\": \"r == 0 and g == 0 and b == 0\",\n"
		"  \"near_black_tolerance\": 0,\n"
		"  \"owner_counts\": [\n",
		width,
		height,
		source_pixels,
		content_pixels,
		black_pixels,
		unresolved_pixels,
		background_pixels,
		owned_black_pixels);
	bool first = true;
	for (uint32_t code = 1; code < OSRS_OWNER_CODE_COUNT; ++code)
	{
		if (owner_total[code] == 0)
		{
			continue;
		}
		fprintf(output,
			"%s    {\"code\": %u, \"total_pixels\": %" PRIu64
			", \"content_bearing_pixels\": %" PRIu64
			", \"pixel_bounds\": [%u, %u, %u, %u]}",
			first ? "" : ",\n",
			code,
			owner_total[code],
			owner_content[code],
			owner_min_x[code],
			owner_min_y[code],
			owner_max_x[code] + 1u,
			owner_max_y[code] + 1u);
		first = false;
	}
	fprintf(output,
		"\n  ],\n"
		"  \"checks\": {\n"
		"    \"category_sum_matches_source\": %s,\n"
		"    \"zero_unresolved_content_bearing_pixels\": %s,\n"
		"    \"release_ready\": %s\n"
		"  }\n"
		"}\n",
		(content_pixels + black_pixels == source_pixels) ? "true" : "false",
		unresolved_pixels == 0 ? "true" : "false",
		(content_pixels + black_pixels == source_pixels && unresolved_pixels == 0)
			? "true" : "false");
	if (fclose(output) != 0)
	{
		fprintf(stderr, "cannot finalize %s: %s\n", path, strerror(errno));
		return false;
	}
	return true;
}

int main(int argc, char **argv)
{
	const char *source_path = NULL;
	const char *owners_path = NULL;
	const char *output_path = NULL;
	bool require_zero = false;
	for (int index = 1; index < argc; ++index)
	{
		if (strcmp(argv[index], "--source") == 0 && index + 1 < argc)
		{
			source_path = argv[++index];
		}
		else if (strcmp(argv[index], "--owners") == 0 && index + 1 < argc)
		{
			owners_path = argv[++index];
		}
		else if (strcmp(argv[index], "--output") == 0 && index + 1 < argc)
		{
			output_path = argv[++index];
		}
		else if (strcmp(argv[index], "--require-zero") == 0)
		{
			require_zero = true;
		}
		else
		{
			osrsUsage(argv[0]);
			return 64;
		}
	}
	if (source_path == NULL || owners_path == NULL || output_path == NULL)
	{
		osrsUsage(argv[0]);
		return 64;
	}

	osrsPngReader source;
	osrsPngReader owners;
	if (!osrsOpenReader(source_path, &source) || !osrsOpenReader(owners_path, &owners))
	{
		osrsCloseReader(&source);
		osrsCloseReader(&owners);
		return 65;
	}
	if (source.bit_depth != 8 || source.color_type != PNG_COLOR_TYPE_RGB ||
		source.row_bytes != (size_t) source.width * 3u)
	{
		fprintf(stderr, "source must be an 8-bit RGB PNG\n");
		osrsCloseReader(&source);
		osrsCloseReader(&owners);
		return 65;
	}
	if (owners.bit_depth != 16 || owners.color_type != PNG_COLOR_TYPE_GRAY ||
		owners.row_bytes != (size_t) owners.width * 2u)
	{
		fprintf(stderr, "owners must be a 16-bit grayscale PNG\n");
		osrsCloseReader(&source);
		osrsCloseReader(&owners);
		return 65;
	}
	if (source.width != owners.width || source.height != owners.height)
	{
		fprintf(stderr, "source and owner dimensions differ\n");
		osrsCloseReader(&source);
		osrsCloseReader(&owners);
		return 65;
	}

	png_bytep source_row = malloc(source.row_bytes);
	png_bytep owner_row = malloc(owners.row_bytes);
	uint64_t *owner_total = calloc(OSRS_OWNER_CODE_COUNT, sizeof(uint64_t));
	uint64_t *owner_content = calloc(OSRS_OWNER_CODE_COUNT, sizeof(uint64_t));
	uint32_t *owner_min_x = malloc(OSRS_OWNER_CODE_COUNT * sizeof(uint32_t));
	uint32_t *owner_min_y = malloc(OSRS_OWNER_CODE_COUNT * sizeof(uint32_t));
	uint32_t *owner_max_x = calloc(OSRS_OWNER_CODE_COUNT, sizeof(uint32_t));
	uint32_t *owner_max_y = calloc(OSRS_OWNER_CODE_COUNT, sizeof(uint32_t));
	if (source_row == NULL || owner_row == NULL || owner_total == NULL || owner_content == NULL ||
		owner_min_x == NULL || owner_min_y == NULL || owner_max_x == NULL || owner_max_y == NULL)
	{
		fprintf(stderr, "allocation failure\n");
		free(source_row);
		free(owner_row);
		free(owner_total);
		free(owner_content);
		free(owner_min_x);
		free(owner_min_y);
		free(owner_max_x);
		free(owner_max_y);
		osrsCloseReader(&source);
		osrsCloseReader(&owners);
		return 70;
	}
	for (uint32_t code = 0; code < OSRS_OWNER_CODE_COUNT; ++code)
	{
		owner_min_x[code] = UINT32_MAX;
		owner_min_y[code] = UINT32_MAX;
	}

	uint64_t content_pixels = 0;
	uint64_t black_pixels = 0;
	uint64_t unresolved_pixels = 0;
	uint64_t background_pixels = 0;
	uint64_t owned_black_pixels = 0;
	bool read_failed = false;
	if (setjmp(png_jmpbuf(source.png)) != 0 || setjmp(png_jmpbuf(owners.png)) != 0)
	{
		read_failed = true;
	}
	else
	{
		for (png_uint_32 y = 0; y < source.height; ++y)
		{
			png_read_row(source.png, source_row, NULL);
			png_read_row(owners.png, owner_row, NULL);
			for (png_uint_32 x = 0; x < source.width; ++x)
			{
				const bool content = source_row[x * 3u] != 0 ||
					source_row[x * 3u + 1u] != 0 || source_row[x * 3u + 2u] != 0;
				const uint16_t code = osrsReadBigEndianU16(&owner_row[x * 2u]);
				if (content)
				{
					++content_pixels;
					if (code == 0)
					{
						++unresolved_pixels;
					}
				}
				else
				{
					++black_pixels;
					if (code == 0)
					{
						++background_pixels;
					}
					else
					{
						++owned_black_pixels;
					}
				}
				if (code != 0)
				{
					++owner_total[code];
					owner_content[code] += content ? 1u : 0u;
					if (x < owner_min_x[code])
					{
						owner_min_x[code] = x;
					}
					if (y < owner_min_y[code])
					{
						owner_min_y[code] = y;
					}
					if (x > owner_max_x[code])
					{
						owner_max_x[code] = x;
					}
					if (y > owner_max_y[code])
					{
						owner_max_y[code] = y;
					}
				}
			}
		}
		png_read_end(source.png, source.info);
		png_read_end(owners.png, owners.info);
	}
	const uint64_t source_pixels = (uint64_t) source.width * source.height;
	const bool wrote = !read_failed && osrsWriteJson(
		output_path,
		source.width,
		source.height,
		source_pixels,
		content_pixels,
		black_pixels,
		unresolved_pixels,
		background_pixels,
		owned_black_pixels,
		owner_total,
		owner_content,
		owner_min_x,
		owner_min_y,
		owner_max_x,
		owner_max_y);

	free(source_row);
	free(owner_row);
	free(owner_total);
	free(owner_content);
	free(owner_min_x);
	free(owner_min_y);
	free(owner_max_x);
	free(owner_max_y);
	osrsCloseReader(&source);
	osrsCloseReader(&owners);
	if (!wrote)
	{
		return 65;
	}
	if (require_zero && unresolved_pixels != 0)
	{
		fprintf(stderr, "unresolved content-bearing pixels: %" PRIu64 "\n", unresolved_pixels);
		return 2;
	}
	return 0;
}
