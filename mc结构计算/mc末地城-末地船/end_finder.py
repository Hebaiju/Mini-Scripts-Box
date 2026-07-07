#!/usr/bin/env python3
"""
Standalone Minecraft Java End City / End Ship finder.

This is a focused Python port of the parts needed for Java 1.20 End City
placement, End biome/terrain validation, and End City piece generation.
It has no dependency on cubiomes or any third-party Python package.
"""

from __future__ import annotations

import argparse
import math
from dataclasses import dataclass
from typing import Callable, Iterable


MASK48 = (1 << 48) - 1
MASK64 = (1 << 64) - 1
JAVA_MULT = 0x5DEECE66D
JAVA_ADD = 0xB

END_CITY_SALT = 10387313
END_CITY_REGION_SIZE = 20
END_CITY_CHUNK_RANGE = 9
END_CITY_MIN_DIST = 1008


def to_u64(value: int) -> int:
    return value & MASK64


def trunc_div(a: int, b: int) -> int:
    q = abs(a) // abs(b)
    return -q if (a < 0) ^ (b < 0) else q


def c_remainder(a: int, b: int) -> int:
    return a - trunc_div(a, b) * b


class JavaRandom:
    def __init__(self, seed: int = 0) -> None:
        self.set_seed(seed)

    def set_seed(self, value: int) -> None:
        self.seed = (value ^ JAVA_MULT) & MASK48

    def next_bits_unsigned(self, bits: int) -> int:
        self.seed = (self.seed * JAVA_MULT + JAVA_ADD) & MASK48
        return self.seed >> (48 - bits)

    def next_bits_signed(self, bits: int) -> int:
        value = self.next_bits_unsigned(bits)
        if bits == 32 and value >= (1 << 31):
            value -= 1 << 32
        return value

    def next_int(self, n: int) -> int:
        if n <= 0:
            raise ValueError("next_int bound must be positive")
        m = n - 1
        if (m & n) == 0:
            return (n * self.next_bits_unsigned(31)) >> 31
        while True:
            bits = self.next_bits_unsigned(31)
            value = bits % n
            if ((bits - value + m) & 0xFFFFFFFF) < 0x80000000:
                return value

    def next_long_unsigned(self) -> int:
        hi = self.next_bits_signed(32)
        lo = self.next_bits_signed(32)
        return (((hi & MASK64) << 32) + (lo & MASK64)) & MASK64

    def next_double(self) -> float:
        return ((self.next_bits_unsigned(26) << 27) + self.next_bits_unsigned(27)) / float(1 << 53)

    def skip(self, n: int) -> None:
        mul = 1
        add = 0
        imul = JAVA_MULT
        iadd = JAVA_ADD
        while n:
            if n & 1:
                mul = (mul * imul) & MASK48
                add = (imul * add + iadd) & MASK48
            iadd = ((imul + 1) * iadd) & MASK48
            imul = (imul * imul) & MASK48
            n >>= 1
        self.seed = (self.seed * mul + add) & MASK48


def chunk_generate_random(world_seed: int, chunk_x: int, chunk_z: int) -> JavaRandom:
    rnd = JavaRandom(world_seed)
    seed = (
        rnd.next_long_unsigned() * to_u64(chunk_x)
        ^ rnd.next_long_unsigned() * to_u64(chunk_z)
        ^ to_u64(world_seed)
    ) & MASK64
    return JavaRandom(seed)


def lerp(part: float, start: float, end: float) -> float:
    return start + part * (end - start)


def lerp2(dx: float, dy: float, v00: float, v10: float, v01: float, v11: float) -> float:
    return lerp(dy, lerp(dx, v00, v10), lerp(dx, v01, v11))


def lerp3(
    dx: float,
    dy: float,
    dz: float,
    v000: float,
    v100: float,
    v010: float,
    v110: float,
    v001: float,
    v101: float,
    v011: float,
    v111: float,
) -> float:
    a = lerp2(dx, dy, v000, v100, v010, v110)
    b = lerp2(dx, dy, v001, v101, v011, v111)
    return lerp(dz, a, b)


def clamped_lerp(part: float, start: float, end: float) -> float:
    if part <= 0:
        return start
    if part >= 1:
        return end
    return lerp(part, start, end)


def indexed_lerp(index: int, a: float, b: float, c: float) -> float:
    index &= 0xF
    if index == 0:
        return a + b
    if index == 1:
        return -a + b
    if index == 2:
        return a - b
    if index == 3:
        return -a - b
    if index == 4:
        return a + c
    if index == 5:
        return -a + c
    if index == 6:
        return a - c
    if index == 7:
        return -a - c
    if index == 8:
        return b + c
    if index == 9:
        return -b + c
    if index == 10:
        return b - c
    if index == 11:
        return -b - c
    if index == 12:
        return a + b
    if index == 13:
        return -b + c
    if index == 14:
        return -a + b
    return -b - c


class PerlinNoise:
    def __init__(self, rnd: JavaRandom) -> None:
        self.a = rnd.next_double() * 256.0
        self.b = rnd.next_double() * 256.0
        self.c = rnd.next_double() * 256.0
        self.d = list(range(256))
        for i in range(256):
            j = rnd.next_int(256 - i) + i
            self.d[i], self.d[j] = self.d[j], self.d[i]
        self.d.append(self.d[0])
        base = math.floor(self.b)
        frac = self.b - base
        self.h2 = int(base) & 0xFF
        self.d2 = frac
        self.t2 = frac * frac * frac * (frac * (frac * 6.0 - 15.0) + 10.0)

    def sample_perlin(self, x: float, y: float, z: float, y_amp: float, y_min: float) -> float:
        if y == 0.0:
            y = self.d2
            h2 = self.h2
            t2 = self.t2
        else:
            y += self.b
            base_y = math.floor(y)
            y -= base_y
            h2 = int(base_y) & 0xFF
            t2 = y * y * y * (y * (y * 6.0 - 15.0) + 10.0)

        x += self.a
        z += self.c
        base_x = math.floor(x)
        base_z = math.floor(z)
        x -= base_x
        z -= base_z
        h1 = int(base_x) & 0xFF
        h3 = int(base_z) & 0xFF
        t1 = x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
        t3 = z * z * z * (z * (z * 6.0 - 15.0) + 10.0)

        if y_amp:
            y_clamp = y_min if y_min < y else y
            y -= math.floor(y_clamp / y_amp) * y_amp

        idx = self.d
        v1a = (idx[h1] + h2) & 0xFF
        v1b = (idx[h1 + 1] + h2) & 0xFF
        v2a = (idx[v1a] + h3) & 0xFF
        v2b = (idx[v1a + 1] + h3) & 0xFF
        v3a = (idx[v1b] + h3) & 0xFF
        v3b = (idx[v1b + 1] + h3) & 0xFF

        v4a, v4b = idx[v2a], idx[v2a + 1]
        v5a, v5b = idx[v2b], idx[v2b + 1]
        v6a, v6b = idx[v3a], idx[v3a + 1]
        v7a, v7b = idx[v3b], idx[v3b + 1]

        l1 = indexed_lerp(v4a, x, y, z)
        l5 = indexed_lerp(v4b, x, y, z - 1)
        l2 = indexed_lerp(v6a, x - 1, y, z)
        l6 = indexed_lerp(v6b, x - 1, y, z - 1)
        l3 = indexed_lerp(v5a, x, y - 1, z)
        l7 = indexed_lerp(v5b, x, y - 1, z - 1)
        l4 = indexed_lerp(v7a, x - 1, y - 1, z)
        l8 = indexed_lerp(v7b, x - 1, y - 1, z - 1)

        l1 = lerp(t1, l1, l2)
        l3 = lerp(t1, l3, l4)
        l5 = lerp(t1, l5, l6)
        l7 = lerp(t1, l7, l8)
        l1 = lerp(t2, l1, l3)
        l5 = lerp(t2, l5, l7)
        return lerp(t3, l1, l5)

    def sample_simplex_2d(self, x: float, y: float) -> float:
        skew = 0.5 * (math.sqrt(3.0) - 1.0)
        unskew = (3.0 - math.sqrt(3.0)) / 6.0
        half = (x + y) * skew
        hx = math.floor(x + half)
        hz = math.floor(y + half)
        mhxz = (hx + hz) * unskew
        x0 = x - (hx - mhxz)
        y0 = y - (hz - mhxz)
        offx = 1 if x0 > y0 else 0
        offz = 0 if offx else 1
        x1 = x0 - offx + unskew
        y1 = y0 - offz + unskew
        x2 = x0 - 1.0 + 2.0 * unskew
        y2 = y0 - 1.0 + 2.0 * unskew

        idx = self.d
        gi0 = idx[0xFF & hz]
        gi1 = idx[0xFF & (hz + offz)]
        gi2 = idx[0xFF & (hz + 1)]
        gi0 = idx[0xFF & (gi0 + hx)]
        gi1 = idx[0xFF & (gi1 + hx + offx)]
        gi2 = idx[0xFF & (gi2 + hx + 1)]

        def grad(gi: int, gx: float, gy: float) -> float:
            con = 0.5 - gx * gx - gy * gy
            if con < 0:
                return 0.0
            con *= con
            return con * con * indexed_lerp(gi % 12, gx, gy, 0.0)

        return 70.0 * (grad(gi0, x0, y0) + grad(gi1, x1, y1) + grad(gi2, x2, y2))


class EndNoise:
    def __init__(self, world_seed: int) -> None:
        rnd = JavaRandom(world_seed)
        rnd.skip(17292)
        self.end_perlin = PerlinNoise(rnd)

        surface_random = JavaRandom(world_seed)
        self.oct_min = [PerlinNoise(surface_random) for _ in range(16)]
        self.oct_max = [PerlinNoise(surface_random) for _ in range(16)]
        self.oct_main = [PerlinNoise(surface_random) for _ in range(8)]

    def end_height_noise(self, x: int, z: int, search_range: int = 0) -> float:
        hx = trunc_div(x, 2)
        hz = trunc_div(z, 2)
        oddx = c_remainder(x, 2)
        oddz = c_remainder(z, 2)
        best = 64 * (x * x + z * z)
        if search_range == 0:
            search_range = 12

        for j in range(-search_range, search_range + 1):
            for i in range(-search_range, search_range + 1):
                rx = hx + i
                rz = hz + j
                if rx * rx + rz * rz <= 4096:
                    continue
                if self.end_perlin.sample_simplex_2d(rx, rz) >= -0.9:
                    continue
                value = int(abs(float(rx)) * 3439.0 + abs(float(rz)) * 147.0) % 13 + 9
                dx = oddx - i * 2
                dz = oddz - j * 2
                noise = (dx * dx + dz * dz) * value * value
                if noise < best:
                    best = noise

        ret = 100.0 - math.sqrt(float(best))
        return max(-100.0, min(80.0, ret))

    def biome_at_chunk(self, chunk_x: int, chunk_z: int) -> str:
        hw = 27
        hmap: list[list[int]] = []
        for j in range(27):
            row: list[int] = []
            for i in range(27):
                rx = chunk_x + i - 12
                rz = chunk_z + j - 12
                value = 0
                if rx * rx + rz * rz > 4096 and self.end_perlin.sample_simplex_2d(rx, rz) < -0.9:
                    value = int(abs(float(rx)) * 3439.0 + abs(float(rz)) * 147.0) % 13 + 9
                    value *= value
                row.append(value)
            hmap.append(row)

        hx = 2 * chunk_x + 1
        hz = 2 * chunk_z + 1
        ds = [625, 529, 441, 361, 289, 225, 169, 121, 81, 49, 25, 9, 1,
              1, 9, 25, 49, 81, 121, 169, 225, 289, 361, 441, 529, 625]
        best = 64 * (hx * hx + hz * hz) if abs(hx) <= 15 and abs(hz) <= 15 else 14401
        off_i = 1 if hx < 0 else 0
        off_j = 1 if hz < 0 else 0

        for j in range(25):
            for i in range(25):
                elev = hmap[j][i]
                if elev:
                    value = (ds[off_i + i] + ds[off_j + j]) * elev
                    if value < best:
                        best = value

        if best < 3600:
            return "end_highlands"
        if best <= 10000:
            return "end_midlands"
        if best <= 14400:
            return "end_barrens"
        return "small_end_islands"

    def sample_surface_between(self, x: int, y: int, z: int, noise_min: float = -128.0, noise_max: float = 128.0) -> float:
        xz_scale = 684.412 * 2.0
        y_scale = 684.412
        vmin = 0.0
        vmax = 0.0
        persist = 1.0 / 32768.0
        amp = 64.0

        for i in range(15, -1, -1):
            dx = x * xz_scale * persist
            dz = z * xz_scale * persist
            sy = y_scale * persist
            dy = y * sy
            vmin += self.oct_min[i].sample_perlin(dx, dy, dz, sy, dy) * amp
            vmax += self.oct_max[i].sample_perlin(dx, dy, dz, sy, dy) * amp
            if vmin - amp > noise_max and vmax - amp > noise_max:
                return noise_max
            if vmin + amp < noise_min and vmax + amp < noise_min:
                return noise_min
            amp *= 0.5
            persist *= 2.0

        xz_step = xz_scale / 80.0
        y_step = y_scale / 160.0
        vmain = 0.5
        persist = 1.0 / 128.0
        amp = 0.05 * 128.0

        for i in range(7, -1, -1):
            dx = x * xz_step * persist
            dz = z * xz_step * persist
            sy = y_step * persist
            dy = y * sy
            vmain += self.oct_main[i].sample_perlin(dx, dy, dz, sy, dy) * amp
            if vmain - amp > 1:
                return vmax
            if vmain + amp < 0:
                return vmin
            amp *= 0.5
            persist *= 2.0

        return clamped_lerp(vmain, vmin, vmax)

    def sample_noise_column_end(self, x: int, z: int, y0: int, y1: int) -> list[float]:
        upper_drop = [1.0] * 15 + [
            63 / 64, 62 / 64, 61 / 64, 60 / 64, 59 / 64, 58 / 64, 57 / 64, 56 / 64,
            55 / 64, 54 / 64, 53 / 64, 52 / 64, 51 / 64, 50 / 64, 49 / 64, 48 / 64,
            47 / 64, 46 / 64,
        ]
        lower_drop = [0.0, 0.0, 1 / 7, 2 / 7, 3 / 7, 4 / 7, 5 / 7, 6 / 7] + [1.0] * 25
        depth = self.end_height_noise(x, z) - 8.0
        column: list[float] = []
        for y in range(y0, y1 + 1):
            if lower_drop[y] == 0.0:
                column.append(-30.0)
                continue
            noise = self.sample_surface_between(x, y, z)
            clamped = noise + depth
            clamped = lerp(upper_drop[y], -3000.0, clamped)
            clamped = lerp(lower_drop[y], -30.0, clamped)
            column.append(clamped)
        return column

    @staticmethod
    def surface_height(
        n00: list[float],
        n01: list[float],
        n10: list[float],
        n11: list[float],
        y0: int,
        y1: int,
        blocks_per_cell: int,
        dx: float,
        dz: float,
    ) -> int:
        for celly in range(y1 - 1, y0 - 1, -1):
            idx = celly - y0
            v000, v001, v100, v101 = n00[idx], n01[idx], n10[idx], n11[idx]
            v010, v011, v110, v111 = n00[idx + 1], n01[idx + 1], n10[idx + 1], n11[idx + 1]
            for y in range(blocks_per_cell - 1, -1, -1):
                dy = y / float(blocks_per_cell)
                noise = lerp3(dy, dx, dz, v000, v010, v100, v110, v001, v011, v101, v111)
                if noise > 0:
                    return celly * blocks_per_cell + y
        return 0

    def viable_end_city_terrain(self, world_seed: int, block_x: int, block_z: int) -> tuple[int, tuple[int, int, int, int], int]:
        chunk_x = block_x >> 4
        chunk_z = block_z >> 4
        block_x = chunk_x * 16 + 7
        block_z = chunk_z * 16 + 7
        cell_x = block_x >> 3
        cell_z = block_z >> 3
        y0, y1 = 15, 18

        columns: dict[tuple[int, int], list[float]] = {}

        def col(dx: int, dz: int) -> list[float]:
            key = (dx, dz)
            if key not in columns:
                columns[key] = self.sample_noise_column_end(cell_x + dx, cell_z + dz, y0, y1)
            return columns[key]

        h00 = self.surface_height(col(0, 0), col(0, 1), col(1, 0), col(1, 1), y0, y1, 4, (block_x & 7) / 8.0, (block_z & 7) / 8.0)
        rnd = chunk_generate_random(world_seed, chunk_x, chunk_z)
        rotation = rnd.next_int(4)

        if rotation == 0:
            h01 = self.surface_height(col(0, 1), col(0, 2), col(1, 1), col(1, 2), y0, y1, 4, (block_x & 7) / 8.0, ((block_z + 5) & 7) / 8.0)
            h10 = self.surface_height(col(1, 0), col(1, 1), col(2, 0), col(2, 1), y0, y1, 4, ((block_x + 5) & 7) / 8.0, (block_z & 7) / 8.0)
            h11 = self.surface_height(col(1, 1), col(1, 2), col(2, 1), col(2, 2), y0, y1, 4, ((block_x + 5) & 7) / 8.0, ((block_z + 5) & 7) / 8.0)
        elif rotation == 1:
            h01 = self.surface_height(col(0, 1), col(0, 2), col(1, 1), col(1, 2), y0, y1, 4, (block_x & 7) / 8.0, ((block_z + 5) & 7) / 8.0)
            h10 = self.surface_height(col(0, 0), col(0, 1), col(1, 0), col(1, 1), y0, y1, 4, ((block_x - 5) & 7) / 8.0, (block_z & 7) / 8.0)
            h11 = self.surface_height(col(0, 1), col(0, 2), col(1, 1), col(1, 2), y0, y1, 4, ((block_x - 5) & 7) / 8.0, ((block_z + 5) & 7) / 8.0)
        elif rotation == 2:
            h01 = self.surface_height(col(0, 0), col(0, 1), col(1, 0), col(1, 1), y0, y1, 4, (block_x & 7) / 8.0, ((block_z - 5) & 7) / 8.0)
            h10 = self.surface_height(col(0, 0), col(0, 1), col(1, 0), col(1, 1), y0, y1, 4, ((block_x - 5) & 7) / 8.0, (block_z & 7) / 8.0)
            h11 = self.surface_height(col(0, 0), col(0, 1), col(1, 0), col(1, 1), y0, y1, 4, ((block_x - 5) & 7) / 8.0, ((block_z - 5) & 7) / 8.0)
        else:
            h01 = self.surface_height(col(0, 0), col(0, 1), col(1, 0), col(1, 1), y0, y1, 4, (block_x & 7) / 8.0, ((block_z - 5) & 7) / 8.0)
            h10 = self.surface_height(col(1, 0), col(1, 1), col(2, 0), col(2, 1), y0, y1, 4, ((block_x + 5) & 7) / 8.0, (block_z & 7) / 8.0)
            h11 = self.surface_height(col(1, 0), col(1, 1), col(2, 0), col(2, 1), y0, y1, 4, ((block_x + 5) & 7) / 8.0, ((block_z - 5) & 7) / 8.0)

        heights = (h00, h01, h10, h11)
        min_height = min(heights)
        return (min_height if min_height >= 60 else 0), heights, rotation


@dataclass
class Pos3:
    x: int
    y: int
    z: int


@dataclass
class Piece:
    name: str
    type: int
    rot: int
    pos: Pos3
    bb0: Pos3
    bb1: Pos3
    depth: int = 0


(
    BASE_FLOOR,
    BASE_ROOF,
    BRIDGE_END,
    BRIDGE_GENTLE_STAIRS,
    BRIDGE_PIECE,
    BRIDGE_STEEP_STAIRS,
    FAT_TOWER_BASE,
    FAT_TOWER_MIDDLE,
    FAT_TOWER_TOP,
    SECOND_FLOOR_1,
    SECOND_FLOOR_2,
    SECOND_ROOF,
    END_SHIP,
    THIRD_FLOOR_1,
    THIRD_FLOOR_2,
    THIRD_ROOF,
    TOWER_BASE,
    TOWER_FLOOR,
    TOWER_PIECE,
    TOWER_TOP,
) = range(20)


PIECE_INFO = [
    (9, 3, 9, "base_floor"),
    (11, 1, 11, "base_roof"),
    (4, 5, 1, "bridge_end"),
    (4, 6, 7, "bridge_gentle_stairs"),
    (4, 5, 3, "bridge_piece"),
    (4, 6, 3, "bridge_steep_stairs"),
    (12, 3, 12, "fat_tower_base"),
    (12, 7, 12, "fat_tower_middle"),
    (16, 5, 16, "fat_tower_top"),
    (11, 7, 11, "second_floor_1"),
    (11, 7, 11, "second_floor_2"),
    (13, 1, 13, "second_roof"),
    (12, 23, 28, "ship"),
    (13, 7, 13, "third_floor_1"),
    (13, 7, 13, "third_floor_2"),
    (15, 1, 15, "third_roof"),
    (6, 6, 6, "tower_base"),
    (6, 3, 6, "tower_floor"),
    (6, 3, 6, "tower_piece"),
    (8, 4, 8, "tower_top"),
]


class PieceEnv:
    def __init__(self, rnd: JavaRandom) -> None:
        self.rnd = rnd
        self.pieces: list[Piece] = []
        self.has_ship = False
        self.y = 0


def add_end_city_piece(env: PieceEnv, prev: Piece | None, rot: int, px: int, py: int, pz: int, typ: int) -> Piece:
    sx, sy, sz, name = PIECE_INFO[typ]
    if prev is None:
        pos = Pos3(px, py, pz)
    else:
        pos = Pos3(prev.pos.x, prev.pos.y, prev.pos.z)

    bb0 = Pos3(pos.x, pos.y, pos.z)
    bb1 = Pos3(pos.x, pos.y + sy, pos.z)
    if rot == 0:
        bb1.x += sx
        bb1.z += sz
    elif rot == 1:
        bb0.x -= sz
        bb1.z += sx
    elif rot == 2:
        bb0.x -= sx
        bb0.z -= sz
    elif rot == 3:
        bb1.x += sz
        bb0.z -= sx
    else:
        raise ValueError("invalid rotation")

    if prev is not None:
        dx, dy, dz = 0, py, 0
        if prev.rot == 0:
            dx += px
            dz += pz
        elif prev.rot == 1:
            dx -= pz
            dz += px
        elif prev.rot == 2:
            dx -= px
            dz -= pz
        elif prev.rot == 3:
            dx += pz
            dz -= px
        pos.x += dx
        pos.y += dy
        pos.z += dz
        bb0.x += dx
        bb0.y += dy
        bb0.z += dz
        bb1.x += dx
        bb1.y += dy
        bb1.z += dz

    piece = Piece(name=name, type=typ, rot=rot, pos=pos, bb0=bb0, bb1=bb1)
    env.pieces.append(piece)
    return piece


def boxes_intersect(a: Piece, b: Piece) -> bool:
    return (
        b.bb1.x >= a.bb0.x and b.bb0.x <= a.bb1.x
        and b.bb1.z >= a.bb0.z and b.bb0.z <= a.bb1.z
        and b.bb1.y >= a.bb0.y and b.bb0.y <= a.bb1.y
    )


PieceGenerator = Callable[[PieceEnv, Piece, int], bool]


def gen_pieces_recursively(gen: PieceGenerator, env: PieceEnv, current: Piece, depth: int) -> bool:
    if depth > 8:
        return False
    start = len(env.pieces)
    if not gen(env, current, depth):
        del env.pieces[start:]
        return False
    local = env.pieces[start:]
    generated_depth = env.rnd.next_bits_signed(32)
    for piece in local:
        piece.depth = generated_depth
        for old in env.pieces[:start]:
            if boxes_intersect(piece, old):
                if current.depth != old.depth:
                    del env.pieces[start:]
                    return False
                break
    return True


def gen_tower(env: PieceEnv, current: Piece, depth: int) -> bool:
    rot = current.rot
    x = 3 + env.rnd.next_int(2)
    z = 3 + env.rnd.next_int(2)
    base = add_end_city_piece(env, current, rot, x, -3, z, TOWER_BASE)
    base = add_end_city_piece(env, base, rot, 0, 7, 0, TOWER_PIECE)
    floor = base if env.rnd.next_int(3) == 0 else None
    floor_count = 1 + env.rnd.next_int(3)
    for i in range(floor_count):
        base = add_end_city_piece(env, base, rot, 0, 4, 0, TOWER_PIECE)
        if i < floor_count - 1 and env.rnd.next_bits_unsigned(1):
            floor = base
    if floor:
        for brot_off, bx, by, bz in [(0, 1, -1, 0), (1, 6, -1, 1), (3, 0, -1, 5), (2, 5, -1, 6)]:
            if not env.rnd.next_bits_unsigned(1):
                continue
            bridge = add_end_city_piece(env, base, (rot + brot_off) & 3, bx, by, bz, BRIDGE_END)
            gen_pieces_recursively(gen_bridge, env, bridge, depth + 1)
    elif depth != 7:
        return gen_pieces_recursively(gen_fat_tower, env, base, depth + 1)
    add_end_city_piece(env, base, rot, -1, 4, -1, TOWER_TOP)
    return True


def gen_bridge(env: PieceEnv, current: Piece, depth: int) -> bool:
    rot = current.rot
    floor_count = 1 + env.rnd.next_int(4)
    base = add_end_city_piece(env, current, rot, 0, 0, -4, BRIDGE_PIECE)
    base.depth = -1
    y = 0
    for _ in range(floor_count):
        if env.rnd.next_bits_unsigned(1):
            base = add_end_city_piece(env, base, rot, 0, y, -4, BRIDGE_PIECE)
            y = 0
            continue
        if env.rnd.next_bits_unsigned(1):
            base = add_end_city_piece(env, base, rot, 0, y, -4, BRIDGE_STEEP_STAIRS)
        else:
            base = add_end_city_piece(env, base, rot, 0, y, -8, BRIDGE_GENTLE_STAIRS)
        y = 4

    if not env.has_ship and env.rnd.next_int(10 - depth) == 0:
        ship_x = -8 + env.rnd.next_int(8)
        ship_z = -70 + env.rnd.next_int(10)
        base = add_end_city_piece(env, base, rot, ship_x, y, ship_z, END_SHIP)
        env.has_ship = True
    else:
        env.y = y + 1
        if not gen_pieces_recursively(gen_house_tower, env, base, depth + 1):
            return False

    base = add_end_city_piece(env, base, (rot + 2) & 3, 4, y, 0, BRIDGE_END)
    base.depth = -1
    return True


def gen_house_tower(env: PieceEnv, current: Piece, depth: int) -> bool:
    if depth > 8:
        return False
    rot = current.rot
    base = add_end_city_piece(env, current, rot, -3, env.y, -11, BASE_FLOOR)
    size = env.rnd.next_int(3)
    if size == 0:
        add_end_city_piece(env, base, rot, -1, 4, -1, BASE_ROOF)
        return True
    base = add_end_city_piece(env, base, rot, -1, 0, -1, SECOND_FLOOR_2)
    if size == 1:
        base = add_end_city_piece(env, base, rot, -1, 8, -1, SECOND_ROOF)
    else:
        base = add_end_city_piece(env, base, rot, -1, 4, -1, THIRD_FLOOR_2)
        base = add_end_city_piece(env, base, rot, -1, 8, -1, THIRD_ROOF)
    gen_pieces_recursively(gen_tower, env, base, depth + 1)
    return True


def gen_fat_tower(env: PieceEnv, current: Piece, depth: int) -> bool:
    rot = current.rot
    base = add_end_city_piece(env, current, rot, -3, 4, -3, FAT_TOWER_BASE)
    base = add_end_city_piece(env, base, rot, 0, 4, 0, FAT_TOWER_MIDDLE)
    bridge_info = [(0, 4, -1, 0), (1, 12, -1, 4), (3, 0, -1, 8), (2, 8, -1, 12)]
    j = 0
    while j < 2 and env.rnd.next_int(3) != 0:
        base = add_end_city_piece(env, base, rot, 0, 8, 0, FAT_TOWER_MIDDLE)
        for brot_off, bx, by, bz in bridge_info:
            if not env.rnd.next_bits_unsigned(1):
                continue
            bridge = add_end_city_piece(env, base, (rot + brot_off) & 3, bx, by, bz, BRIDGE_END)
            gen_pieces_recursively(gen_bridge, env, bridge, depth + 1)
        j += 1
    add_end_city_piece(env, base, rot, -2, 8, -2, FAT_TOWER_TOP)
    return True


def get_end_city_pieces(world_seed: int, chunk_x: int, chunk_z: int) -> list[Piece]:
    rnd = chunk_generate_random(world_seed, chunk_x, chunk_z)
    rot = rnd.next_int(4)
    env = PieceEnv(rnd)
    x = chunk_x * 16 + 8
    z = chunk_z * 16 + 8
    base = add_end_city_piece(env, None, rot, x, 0, z, BASE_FLOOR)
    base = add_end_city_piece(env, base, rot, -1, 0, -1, SECOND_FLOOR_1)
    base = add_end_city_piece(env, base, rot, -1, 4, -1, THIRD_FLOOR_1)
    base = add_end_city_piece(env, base, rot, -1, 8, -1, THIRD_ROOF)
    gen_pieces_recursively(gen_tower, env, base, 1)
    return env.pieces


@dataclass
class EndCityResult:
    x: int
    z: int
    distance: float
    biome: str
    terrain_height: int
    terrain_corner_heights: tuple[int, int, int, int]
    rotation: int
    pieces: int
    has_ship: bool
    ship_x: int | None
    ship_y: int | None
    ship_z: int | None


def large_structure_pos(world_seed: int, region_x: int, region_z: int) -> tuple[int, int]:
    seed = (to_u64(world_seed) + region_x * 341873128712 + region_z * 132897987541 + END_CITY_SALT) & MASK64
    seed = (seed ^ JAVA_MULT) & MASK48

    def step(current: int) -> int:
        return (current * JAVA_MULT + JAVA_ADD) & MASK48

    seed = step(seed)
    x = (seed >> 17) % END_CITY_CHUNK_RANGE
    seed = step(seed)
    x += (seed >> 17) % END_CITY_CHUNK_RANGE
    seed = step(seed)
    z = (seed >> 17) % END_CITY_CHUNK_RANGE
    seed = step(seed)
    z += (seed >> 17) % END_CITY_CHUNK_RANGE
    x >>= 1
    z >>= 1
    return (region_x * END_CITY_REGION_SIZE + x) * 16, (region_z * END_CITY_REGION_SIZE + z) * 16


def iter_end_city_attempts(world_seed: int, center_x: int, center_z: int, radius: int) -> Iterable[tuple[int, int]]:
    blocks_per_region = END_CITY_REGION_SIZE * 16
    min_rx = math.floor((center_x - radius) / blocks_per_region) - 1
    max_rx = math.floor((center_x + radius) / blocks_per_region) + 1
    min_rz = math.floor((center_z - radius) / blocks_per_region) - 1
    max_rz = math.floor((center_z + radius) / blocks_per_region) + 1
    for rz in range(min_rz, max_rz + 1):
        for rx in range(min_rx, max_rx + 1):
            x, z = large_structure_pos(world_seed, rx, rz)
            if x * x + z * z < END_CITY_MIN_DIST * END_CITY_MIN_DIST:
                continue
            if math.hypot(x - center_x, z - center_z) <= radius:
                yield x, z


def find_end_cities(world_seed: int, center_x: int, center_z: int, radius: int, require_ship: bool = False) -> list[EndCityResult]:
    noise = EndNoise(world_seed)
    results: list[EndCityResult] = []
    for x, z in iter_end_city_attempts(world_seed, center_x, center_z, radius):
        biome = noise.biome_at_chunk(x >> 4, z >> 4)
        if biome not in ("end_midlands", "end_highlands"):
            continue
        terrain_height, corner_heights, rotation = noise.viable_end_city_terrain(world_seed, x, z)
        if not terrain_height:
            continue
        pieces = get_end_city_pieces(world_seed, x >> 4, z >> 4)
        ship = next((piece for piece in pieces if piece.type == END_SHIP), None)
        if require_ship and ship is None:
            continue
        results.append(
            EndCityResult(
                x=x,
                z=z,
                distance=math.hypot(x - center_x, z - center_z),
                biome=biome,
                terrain_height=terrain_height,
                terrain_corner_heights=corner_heights,
                rotation=rotation,
                pieces=len(pieces),
                has_ship=ship is not None,
                ship_x=ship.pos.x if ship else None,
                ship_y=ship.pos.y if ship else None,
                ship_z=ship.pos.z if ship else None,
            )
        )
    results.sort(key=lambda item: item.distance)
    return results


def print_results(results: list[EndCityResult]) -> None:
    if not results:
        print("No matching End Cities found.")
        return
    header = "city_x,city_z,distance,biome,terrain_height,has_ship,ship_x,ship_y,ship_z,pieces"
    print(header)
    for r in results:
        print(
            f"{r.x},{r.z},{r.distance:.2f},{r.biome},{r.terrain_height},"
            f"{'yes' if r.has_ship else 'no'},"
            f"{'' if r.ship_x is None else r.ship_x},"
            f"{'' if r.ship_y is None else r.ship_y},"
            f"{'' if r.ship_z is None else r.ship_z},"
            f"{r.pieces}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Find Minecraft Java 1.20 End Cities and End Ships.")
    parser.add_argument("--seed", type=int, required=True, help="World seed.")
    parser.add_argument("--x", "--center-x", dest="center_x", type=int, required=True, help="Search center block X.")
    parser.add_argument("--z", "--center-z", dest="center_z", type=int, required=True, help="Search center block Z.")
    parser.add_argument("--radius", type=int, default=1000, help="Search radius in blocks. Default: 1000.")
    parser.add_argument("--ships-only", action="store_true", help="Only show End Cities that contain an End Ship.")
    parser.add_argument("--version", default="1.20", help="Accepted for CLI compatibility. This tool currently targets Java 1.20.")
    args = parser.parse_args()

    if args.version not in ("1.20", "1.20.1", "1.20.2", "1.20.3", "1.20.4", "1.20.5", "1.20.6"):
        print(f"Warning: version {args.version!r} was requested; this standalone port is currently tuned for Java 1.20.")

    results = find_end_cities(args.seed, args.center_x, args.center_z, args.radius, require_ship=args.ships_only)
    print_results(results)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
