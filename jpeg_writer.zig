// Based on stb_image_write.h
//
// https://raw.githubusercontent.com/nothings/stb/master/stb_image_write.h

const std = @import("std");

const flip_vertically_on_write = false;

// Expects a writer which implements std.io.OutStream.
pub fn writeToStream(writer: var, w: usize, h: usize, comp: usize, data: []const u8, quality: i32) !void {
    try writeToStreamCore(writer, w, h, comp, data, quality);
}

pub fn writeToFile(filename: []const u8, w: usize, h: usize, comp: usize, data: []const u8, quality: i32) !void {
    var file = try std.os.File.openWrite(filename);
    defer file.close();

    var file_stream = file.outStream();
    var buffered_writer = std.io.BufferedOutStream(std.os.File.WriteError).init(&file_stream.stream);
    try writeToStream(&buffered_writer.stream, w, h, comp, data, quality);
    try buffered_writer.flush();
}

const zig_zag_table = []const u8{
    0, 1, 5, 6, 14, 15, 27, 28, 2, 4, 7, 13, 16, 26, 29, 42, 3, 8, 12, 17, 25, 30, 41, 43, 9, 11, 18,
    24, 31, 40, 44, 53, 10, 19, 23, 32, 39, 45, 52, 54, 20, 22, 33, 38, 46, 51, 55, 60, 21, 34, 37, 47, 50, 56,
    59, 61, 35, 36, 48, 49, 57, 58, 62, 63,
};

fn writeBits(writer: var, bitBufP: *u32, bitCntP: *u32, bs: [2]u16) !void {
    var bitBuf = bitBufP.*;
    var bitCnt = bitCntP.*;

    bitCnt += bs[1];
    bitBuf |= std.math.shl(u32, bs[0], 24 - bitCnt);

    while (bitCnt >= 8) : ({
        bitBuf <<= 8;
        bitCnt -= 8;
    }) {
        const c = @truncate(u8, bitBuf >> 16);
        try writer.write([]u8{c});
        if (c == 255) {
            try writer.write([]u8{0});
        }
    }

    bitBufP.* = bitBuf;
    bitCntP.* = bitCnt;
}

fn computeDCT(
    d0p: *f32,
    d1p: *f32,
    d2p: *f32,
    d3p: *f32,
    d4p: *f32,
    d5p: *f32,
    d6p: *f32,
    d7p: *f32,
) void {
    var d0 = d0p.*;
    var d1 = d1p.*;
    var d2 = d2p.*;
    var d3 = d3p.*;
    var d4 = d4p.*;
    var d5 = d5p.*;
    var d6 = d6p.*;
    var d7 = d7p.*;

    const tmp0 = d0 + d7;
    const tmp7 = d0 - d7;
    const tmp1 = d1 + d6;
    const tmp6 = d1 - d6;
    const tmp2 = d2 + d5;
    const tmp5 = d2 - d5;
    const tmp3 = d3 + d4;
    const tmp4 = d3 - d4;

    // Even part
    var tmp10 = tmp0 + tmp3; // phase 2
    var tmp13 = tmp0 - tmp3;
    var tmp11 = tmp1 + tmp2;
    var tmp12 = tmp1 - tmp2;

    d0 = tmp10 + tmp11; // phase 3
    d4 = tmp10 - tmp11;

    const z1 = (tmp12 + tmp13) * 0.707106781; // c4
    d2 = tmp13 + z1; // phase 5
    d6 = tmp13 - z1;

    // Odd part
    tmp10 = tmp4 + tmp5; // phase 2
    tmp11 = tmp5 + tmp6;
    tmp12 = tmp6 + tmp7;

    // The rotator is modified from fig 4-8 to avoid extra negations.
    const z5 = (tmp10 - tmp12) * 0.382683433; // c6
    const z2 = tmp10 * 0.541196100 + z5; // c2-c6
    const z4 = tmp12 * 1.306562965 + z5; // c2+c6
    const z3 = tmp11 * 0.707106781; // c4

    const z11 = tmp7 + z3; // phase 5
    const z13 = tmp7 - z3;

    d5p.* = z13 + z2; // phase 6
    d3p.* = z13 - z2;
    d1p.* = z11 + z4;
    d7p.* = z11 - z4;

    d0p.* = d0;
    d2p.* = d2;
    d4p.* = d4;
    d6p.* = d6;
}

fn calcBits(_val: i32, bits: []u16) void {
    std.debug.assert(bits.len == 2);

    var val = _val;
    var tmp1 = if (val < 0) -val else val;
    val = if (val < 0) val - 1 else val;

    bits[1] = 1;
    while (true) {
        tmp1 >>= 1;
        if (tmp1 == 0) break;
        bits[1] += 1;
    }

    bits[0] = @truncate(u16, @bitCast(u32, val) & (std.math.shl(c_uint, 1, bits[1]) - 1));
}

fn processDU(writer: var, bitBuf: *u32, bitCnt: *u32, CDU: []f32, fdtbl: []f32, DC: i32, HTDC: [256][2]u16, HTAC: [256][2]u16) !i32 {
    std.debug.assert(CDU.len == 64);
    std.debug.assert(fdtbl.len == 64);

    const EOB = []u16{ HTAC[0x00][0], HTAC[0x00][1] };
    const M16zeroes = []u16{ HTAC[0xF0][0], HTAC[0xF0][1] };
    var DU: [64]i32 = undefined;

    // DCT rows
    {
        var i: usize = 0;
        while (i < 64) : (i += 8) {
            computeDCT(&CDU[i], &CDU[i + 1], &CDU[i + 2], &CDU[i + 3], &CDU[i + 4], &CDU[i + 5], &CDU[i + 6], &CDU[i + 7]);
        }
    }

    // DCT columns
    {
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            computeDCT(&CDU[i], &CDU[i + 8], &CDU[i + 16], &CDU[i + 24], &CDU[i + 32], &CDU[i + 40], &CDU[i + 48], &CDU[i + 56]);
        }
    }

    // Quantize/descale/zigzag the coefficients
    {
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const v = CDU[i] * fdtbl[i];
            // DU[zig_zag_table[i]] = (int)(v < 0 ? ceilf(v - 0.5f) : floorf(v + 0.5f));
            // ceilf() and floorf() are C99, not C89, but I /think/ they're not needed here anyway?
            DU[zig_zag_table[i]] = @floatToInt(i32, if (v < 0) v - 0.5 else v + 0.5);
        }
    }

    // Encode DC
    const diff = DU[0] - DC;
    if (diff == 0) {
        try writeBits(writer, bitBuf, bitCnt, HTDC[0]);
    } else {
        var bits: [2]u16 = undefined;
        calcBits(diff, bits[0..]);
        try writeBits(writer, bitBuf, bitCnt, HTDC[bits[1]]);
        try writeBits(writer, bitBuf, bitCnt, bits);
    }

    // Encode ACs
    var end0pos: usize = 63;
    while (end0pos > 0 and DU[end0pos] == 0) {
        end0pos -= 1;
    }

    // end0pos = first element in reverse order !=0
    if (end0pos == 0) {
        try writeBits(writer, bitBuf, bitCnt, EOB);
        return DU[0];
    }

    var i: usize = 1;
    while (i <= end0pos) : (i += 1) {
        const startpos = i;

        var bits: [2]u16 = undefined;
        while (DU[i] == 0 and i <= end0pos) {
            i += 1;
        }

        var nrzeroes = i - startpos;
        if (nrzeroes >= 16) {
            const lng = nrzeroes >> 4;
            var nrmarker: usize = 1;
            while (nrmarker <= lng) : (nrmarker += 1) {
                try writeBits(writer, bitBuf, bitCnt, M16zeroes);
            }
            nrzeroes &= 15;
        }
        calcBits(DU[i], bits[0..]);
        try writeBits(writer, bitBuf, bitCnt, HTAC[(nrzeroes << 4) + bits[1]]);
        try writeBits(writer, bitBuf, bitCnt, bits);
    }
    if (end0pos != 63) {
        try writeBits(writer, bitBuf, bitCnt, EOB);
    }
    return DU[0];
}

const std_dc_luminance_nrcodes = []u8{ 0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const std_dc_luminance_values = []u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const std_ac_luminance_nrcodes = []u8{ 0, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const std_ac_luminance_values = []u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
    0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
};

const std_dc_chrominance_nrcodes = []u8{ 0, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const std_dc_chrominance_values = []u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const std_ac_chrominance_nrcodes = []u8{ 0, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
const std_ac_chrominance_values = []u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
};

// Huffman tables
const YDC_HT = [][2]u16{
    []u16{ 0, 2 }, []u16{ 2, 3 }, []u16{ 3, 3 }, []u16{ 4, 3 }, []u16{ 5, 3 }, []u16{ 6, 3 },
    []u16{ 14, 4 }, []u16{ 30, 5 }, []u16{ 62, 6 }, []u16{ 126, 7 }, []u16{ 254, 8 }, []u16{ 510, 9 },
} ++ ([][2]u16{[]u16{ 0, 0 }}) ** 244;

const UVDC_HT = [12][2]u16{
    []u16{ 0, 2 }, []u16{ 1, 2 }, []u16{ 2, 2 }, []u16{ 6, 3 }, []u16{ 14, 4 }, []u16{ 30, 5 },
    []u16{ 62, 6 }, []u16{ 126, 7 }, []u16{ 254, 8 }, []u16{ 510, 9 }, []u16{ 1022, 10 }, []u16{ 2046, 11 },
} ++ ([][2]u16{[]u16{ 0, 0 }}) ** 244;

const YAC_HT = [256][2]u16{
    []u16{ 10, 4 }, []u16{ 0, 2 }, []u16{ 1, 2 }, []u16{ 4, 3 },
    []u16{ 11, 4 }, []u16{ 26, 5 }, []u16{ 120, 7 }, []u16{ 248, 8 },
    []u16{ 1014, 10 }, []u16{ 65410, 16 }, []u16{ 65411, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 12, 4 }, []u16{ 27, 5 }, []u16{ 121, 7 },
    []u16{ 502, 9 }, []u16{ 2038, 11 }, []u16{ 65412, 16 }, []u16{ 65413, 16 },
    []u16{ 65414, 16 }, []u16{ 65415, 16 }, []u16{ 65416, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 28, 5 }, []u16{ 249, 8 }, []u16{ 1015, 10 },
    []u16{ 4084, 12 }, []u16{ 65417, 16 }, []u16{ 65418, 16 }, []u16{ 65419, 16 },
    []u16{ 65420, 16 }, []u16{ 65421, 16 }, []u16{ 65422, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 58, 6 }, []u16{ 503, 9 }, []u16{ 4085, 12 },
    []u16{ 65423, 16 }, []u16{ 65424, 16 }, []u16{ 65425, 16 }, []u16{ 65426, 16 },
    []u16{ 65427, 16 }, []u16{ 65428, 16 }, []u16{ 65429, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 59, 6 }, []u16{ 1016, 10 }, []u16{ 65430, 16 },
    []u16{ 65431, 16 }, []u16{ 65432, 16 }, []u16{ 65433, 16 }, []u16{ 65434, 16 },
    []u16{ 65435, 16 }, []u16{ 65436, 16 }, []u16{ 65437, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 122, 7 }, []u16{ 2039, 11 }, []u16{ 65438, 16 },
    []u16{ 65439, 16 }, []u16{ 65440, 16 }, []u16{ 65441, 16 }, []u16{ 65442, 16 },
    []u16{ 65443, 16 }, []u16{ 65444, 16 }, []u16{ 65445, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 123, 7 }, []u16{ 4086, 12 }, []u16{ 65446, 16 },
    []u16{ 65447, 16 }, []u16{ 65448, 16 }, []u16{ 65449, 16 }, []u16{ 65450, 16 },
    []u16{ 65451, 16 }, []u16{ 65452, 16 }, []u16{ 65453, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 250, 8 }, []u16{ 4087, 12 }, []u16{ 65454, 16 },
    []u16{ 65455, 16 }, []u16{ 65456, 16 }, []u16{ 65457, 16 }, []u16{ 65458, 16 },
    []u16{ 65459, 16 }, []u16{ 65460, 16 }, []u16{ 65461, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 504, 9 }, []u16{ 32704, 15 }, []u16{ 65462, 16 },
    []u16{ 65463, 16 }, []u16{ 65464, 16 }, []u16{ 65465, 16 }, []u16{ 65466, 16 },
    []u16{ 65467, 16 }, []u16{ 65468, 16 }, []u16{ 65469, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 505, 9 }, []u16{ 65470, 16 }, []u16{ 65471, 16 },
    []u16{ 65472, 16 }, []u16{ 65473, 16 }, []u16{ 65474, 16 }, []u16{ 65475, 16 },
    []u16{ 65476, 16 }, []u16{ 65477, 16 }, []u16{ 65478, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 506, 9 }, []u16{ 65479, 16 }, []u16{ 65480, 16 },
    []u16{ 65481, 16 }, []u16{ 65482, 16 }, []u16{ 65483, 16 }, []u16{ 65484, 16 },
    []u16{ 65485, 16 }, []u16{ 65486, 16 }, []u16{ 65487, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 1017, 10 }, []u16{ 65488, 16 }, []u16{ 65489, 16 },
    []u16{ 65490, 16 }, []u16{ 65491, 16 }, []u16{ 65492, 16 }, []u16{ 65493, 16 },
    []u16{ 65494, 16 }, []u16{ 65495, 16 }, []u16{ 65496, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 1018, 10 }, []u16{ 65497, 16 }, []u16{ 65498, 16 },
    []u16{ 65499, 16 }, []u16{ 65500, 16 }, []u16{ 65501, 16 }, []u16{ 65502, 16 },
    []u16{ 65503, 16 }, []u16{ 65504, 16 }, []u16{ 65505, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 2040, 11 }, []u16{ 65506, 16 }, []u16{ 65507, 16 },
    []u16{ 65508, 16 }, []u16{ 65509, 16 }, []u16{ 65510, 16 }, []u16{ 65511, 16 },
    []u16{ 65512, 16 }, []u16{ 65513, 16 }, []u16{ 65514, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 65515, 16 }, []u16{ 65516, 16 }, []u16{ 65517, 16 },
    []u16{ 65518, 16 }, []u16{ 65519, 16 }, []u16{ 65520, 16 }, []u16{ 65521, 16 },
    []u16{ 65522, 16 }, []u16{ 65523, 16 }, []u16{ 65524, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 2041, 11 }, []u16{ 65525, 16 }, []u16{ 65526, 16 }, []u16{ 65527, 16 },
    []u16{ 65528, 16 }, []u16{ 65529, 16 }, []u16{ 65530, 16 }, []u16{ 65531, 16 },
    []u16{ 65532, 16 }, []u16{ 65533, 16 }, []u16{ 65534, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
};

const UVAC_HT = [256][2]u16{
    []u16{ 0, 2 }, []u16{ 1, 2 }, []u16{ 4, 3 }, []u16{ 10, 4 },
    []u16{ 24, 5 }, []u16{ 25, 5 }, []u16{ 56, 6 }, []u16{ 120, 7 },
    []u16{ 500, 9 }, []u16{ 1014, 10 }, []u16{ 4084, 12 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 11, 4 }, []u16{ 57, 6 }, []u16{ 246, 8 },
    []u16{ 501, 9 }, []u16{ 2038, 11 }, []u16{ 4085, 12 }, []u16{ 65416, 16 },
    []u16{ 65417, 16 }, []u16{ 65418, 16 }, []u16{ 65419, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 26, 5 }, []u16{ 247, 8 }, []u16{ 1015, 10 },
    []u16{ 4086, 12 }, []u16{ 32706, 15 }, []u16{ 65420, 16 }, []u16{ 65421, 16 },
    []u16{ 65422, 16 }, []u16{ 65423, 16 }, []u16{ 65424, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 27, 5 }, []u16{ 248, 8 }, []u16{ 1016, 10 },
    []u16{ 4087, 12 }, []u16{ 65425, 16 }, []u16{ 65426, 16 }, []u16{ 65427, 16 },
    []u16{ 65428, 16 }, []u16{ 65429, 16 }, []u16{ 65430, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 58, 6 }, []u16{ 502, 9 }, []u16{ 65431, 16 },
    []u16{ 65432, 16 }, []u16{ 65433, 16 }, []u16{ 65434, 16 }, []u16{ 65435, 16 },
    []u16{ 65436, 16 }, []u16{ 65437, 16 }, []u16{ 65438, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 59, 6 }, []u16{ 1017, 10 }, []u16{ 65439, 16 },
    []u16{ 65440, 16 }, []u16{ 65441, 16 }, []u16{ 65442, 16 }, []u16{ 65443, 16 },
    []u16{ 65444, 16 }, []u16{ 65445, 16 }, []u16{ 65446, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 121, 7 }, []u16{ 2039, 11 }, []u16{ 65447, 16 },
    []u16{ 65448, 16 }, []u16{ 65449, 16 }, []u16{ 65450, 16 }, []u16{ 65451, 16 },
    []u16{ 65452, 16 }, []u16{ 65453, 16 }, []u16{ 65454, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 122, 7 }, []u16{ 2040, 11 }, []u16{ 65455, 16 },
    []u16{ 65456, 16 }, []u16{ 65457, 16 }, []u16{ 65458, 16 }, []u16{ 65459, 16 },
    []u16{ 65460, 16 }, []u16{ 65461, 16 }, []u16{ 65462, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 249, 8 }, []u16{ 65463, 16 }, []u16{ 65464, 16 },
    []u16{ 65465, 16 }, []u16{ 65466, 16 }, []u16{ 65467, 16 }, []u16{ 65468, 16 },
    []u16{ 65469, 16 }, []u16{ 65470, 16 }, []u16{ 65471, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 503, 9 }, []u16{ 65472, 16 }, []u16{ 65473, 16 },
    []u16{ 65474, 16 }, []u16{ 65475, 16 }, []u16{ 65476, 16 }, []u16{ 65477, 16 },
    []u16{ 65478, 16 }, []u16{ 65479, 16 }, []u16{ 65480, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 504, 9 }, []u16{ 65481, 16 }, []u16{ 65482, 16 },
    []u16{ 65483, 16 }, []u16{ 65484, 16 }, []u16{ 65485, 16 }, []u16{ 65486, 16 },
    []u16{ 65487, 16 }, []u16{ 65488, 16 }, []u16{ 65489, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 505, 9 }, []u16{ 65490, 16 }, []u16{ 65491, 16 },
    []u16{ 65492, 16 }, []u16{ 65493, 16 }, []u16{ 65494, 16 }, []u16{ 65495, 16 },
    []u16{ 65496, 16 }, []u16{ 65497, 16 }, []u16{ 65498, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 506, 9 }, []u16{ 65499, 16 }, []u16{ 65500, 16 },
    []u16{ 65501, 16 }, []u16{ 65502, 16 }, []u16{ 65503, 16 }, []u16{ 65504, 16 },
    []u16{ 65505, 16 }, []u16{ 65506, 16 }, []u16{ 65507, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 2041, 11 }, []u16{ 65508, 16 }, []u16{ 65509, 16 },
    []u16{ 65510, 16 }, []u16{ 65511, 16 }, []u16{ 65512, 16 }, []u16{ 65513, 16 },
    []u16{ 65514, 16 }, []u16{ 65515, 16 }, []u16{ 65516, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 16352, 14 }, []u16{ 65517, 16 }, []u16{ 65518, 16 },
    []u16{ 65519, 16 }, []u16{ 65520, 16 }, []u16{ 65521, 16 }, []u16{ 65522, 16 },
    []u16{ 65523, 16 }, []u16{ 65524, 16 }, []u16{ 65525, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
    []u16{ 1018, 10 }, []u16{ 32707, 15 }, []u16{ 65526, 16 }, []u16{ 65527, 16 },
    []u16{ 65528, 16 }, []u16{ 65529, 16 }, []u16{ 65530, 16 }, []u16{ 65531, 16 },
    []u16{ 65532, 16 }, []u16{ 65533, 16 }, []u16{ 65534, 16 }, []u16{ 0, 0 },
    []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 }, []u16{ 0, 0 },
};
const YQT = []i32{
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62, 18, 22,
    37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
};
const UVQT = []i32{
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
};
const aasf = []f32{
    1.0 * 2.828427125, 1.387039845 * 2.828427125, 1.306562965 * 2.828427125, 1.175875602 * 2.828427125,
    1.0 * 2.828427125, 0.785694958 * 2.828427125, 0.541196100 * 2.828427125, 0.275899379 * 2.828427125,
};

fn writeToStreamCore(writer: var, width: usize, height: usize, comp: usize, data: []const u8, _quality: i32) !void {
    if (width == 0 or height == 0 or comp > 4 or comp < 1) {
        return error.InvalidArguments;
    }

    var fdtbl_Y: [64]f32 = undefined;
    var fdtbl_UV: [64]f32 = undefined;
    var YTable: [64]u8 = undefined;
    var UVTable: [64]u8 = undefined;

    var quality = if (_quality != 0) _quality else 90;
    quality = if (quality < 1) 1 else (if (quality > 100) 100 else quality);
    quality = if (quality < 50) @divFloor(5000, quality) else 200 - quality * 2;

    {
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const yti = @divFloor(YQT[i] * quality + 50, 100);
            YTable[zig_zag_table[i]] = @intCast(u8, if (yti < 1) 1 else (if (yti > 255) 255 else yti));
            const uvti = @divFloor(UVQT[i] * quality + 50, 100);
            UVTable[zig_zag_table[i]] = @intCast(u8, if (uvti < 1) 1 else (if (uvti > 255) 255 else uvti));
        }
    }

    {
        var row: usize = 0;
        var k: usize = 0;
        while (row < 8) : (row += 1) {
            var col: usize = 0;
            while (col < 8) : ({
                col += 1;
                k += 1;
            }) {
                fdtbl_Y[k] = 1 / (@intToFloat(f32, YTable[zig_zag_table[k]]) * aasf[row] * aasf[col]);
                fdtbl_UV[k] = 1 / (@intToFloat(f32, UVTable[zig_zag_table[k]]) * aasf[row] * aasf[col]);
            }
        }
    }

    // Write Headers
    {
        const head0 = []u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xDB, 0, 0x84, 0 };
        const head2 = []u8{ 0xFF, 0xDA, 0, 0xC, 3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0 };
        const head1 = []u8{
            0xFF, 0xC0, 0, 0x11, 8, @truncate(u8, height >> 8), @truncate(u8, height), @truncate(u8, width >> 8), @truncate(u8, width),
            3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11,
            1, 0xFF, 0xC4, 0x01, 0xA2, 0,
        };

        try writer.write(head0);
        try writer.write(YTable);
        try writer.write([]u8{1});
        try writer.write(UVTable);
        try writer.write(head1);
        try writer.write(std_dc_luminance_nrcodes[1..]);
        try writer.write(std_dc_luminance_values);
        try writer.write([]u8{0x10}); // HTYACinfo
        try writer.write(std_ac_luminance_nrcodes[1..]);
        try writer.write(std_ac_luminance_values);
        try writer.write([]u8{1}); //HTUDCinfo
        try writer.write(std_dc_chrominance_nrcodes[1..]);
        try writer.write(std_dc_chrominance_values);
        try writer.write([]u8{0x11}); // HTUACinfo
        try writer.write(std_ac_chrominance_nrcodes[1..]);
        try writer.write(std_ac_chrominance_values);
        try writer.write(head2);
    }

    // Encode 8x8 macroblocks
    {
        const fillBits = []u16{ 0x7F, 7 };

        var DCY: i32 = 0;
        var DCU: i32 = 0;
        var DCV: i32 = 0;

        var bitBuf: u32 = 0;
        var bitCnt: u32 = 0;

        // comp == 2 is grey+alpha (alpha is ignored)
        const ofsG = if (comp > 2) usize(1) else 0;
        const ofsB = if (comp > 2) usize(2) else 0;

        var y: usize = 0;
        while (y < height) : (y += 8) {
            var x: usize = 0;
            while (x < width) : (x += 8) {
                var YDU: [64]f32 = undefined;
                var UDU: [64]f32 = undefined;
                var VDU: [64]f32 = undefined;

                var row = y;
                var pos: usize = 0;
                while (row < y + 8) : (row += 1) {
                    var col = x;
                    while (col < x + 8) : ({
                        col += 1;
                        pos += 1;
                    }) {
                        var p = (if (flip_vertically_on_write) height - 1 - row else row) * width * comp + col * comp;

                        if (row >= height) {
                            p -= width * comp * (row + 1 - height);
                        }
                        if (col >= width) {
                            p -= comp * (col + 1 - width);
                        }

                        const r = @intToFloat(f32, data[p + 0]);
                        const g = @intToFloat(f32, data[p + ofsG]);
                        const b = @intToFloat(f32, data[p + ofsB]);
                        YDU[pos] = 0.29900 * r + 0.58700 * g + 0.11400 * b - 128;
                        UDU[pos] = -0.16874 * r - 0.33126 * g + 0.50000 * b;
                        VDU[pos] = 0.50000 * r - 0.41869 * g - 0.08131 * b;
                    }
                }

                DCY = try processDU(writer, &bitBuf, &bitCnt, YDU[0..], fdtbl_Y[0..], DCY, YDC_HT, YAC_HT);
                DCU = try processDU(writer, &bitBuf, &bitCnt, UDU[0..], fdtbl_UV[0..], DCU, UVDC_HT, UVAC_HT);
                DCV = try processDU(writer, &bitBuf, &bitCnt, VDU[0..], fdtbl_UV[0..], DCV, UVDC_HT, UVAC_HT);
            }
        }

        // Do the bit alignment of the EOI marker
        try writeBits(writer, &bitBuf, &bitCnt, fillBits);
    }

    // EOI
    try writer.write([]u8{0xFF});
    try writer.write([]u8{0xD9});
}
