// Draco's corner tables (mesh/corner_table.h, mesh_attribute_corner_table.h,
// corner_table_iterators.h) and MeshAttributeIndicesEncodingData, ported
// from Google's Draco decoder (Apache License 2.0,
// https://github.com/google/draco) to AnimaScript. Indices are i32 with -1
// for kInvalidCornerIndex / kInvalidVertexIndex.

export const INVALID_INDEX: i32 = -1;

/// The corner table interface the traversers and predictors use
/// (Draco's CornerTable and MeshAttributeCornerTable templates).
export abstract class CornerTableBase {
    abstract numVertices(): i32;
    abstract numCorners(): i32;
    abstract numFaces(): i32;
    abstract opposite(corner: i32): i32;
    abstract vertex(corner: i32): i32;
    abstract leftMostCorner(v: i32): i32;

    @inline next(corner: i32): i32 {
        if (corner < 0) return corner;
        return (corner % 3) == 2 ? corner - 2 : corner + 1;
    }

    @inline previous(corner: i32): i32 {
        if (corner < 0) return corner;
        return (corner % 3) == 0 ? corner + 2 : corner - 1;
    }

    swingRight(corner: i32): i32 { return this.previous(this.opposite(this.previous(corner))); }
    swingLeft(corner: i32): i32 { return this.next(this.opposite(this.next(corner))); }

    getLeftCorner(corner: i32): i32 {
        if (corner < 0) return INVALID_INDEX;
        return this.opposite(this.previous(corner));
    }

    getRightCorner(corner: i32): i32 {
        if (corner < 0) return INVALID_INDEX;
        return this.opposite(this.next(corner));
    }

    abstract isOnBoundary(v: i32): bool;
}

/// CornerTable: the connectivity of the mesh's vertices.
export class CornerTable extends CornerTableBase {
    cornerToVertex: Int32Array = new Int32Array(0);
    oppositeCorners: Int32Array = new Int32Array(0);
    vertexCorners: Int32Array = new Int32Array(0);
    vertexCount: i32 = 0;

    /// Reset(num_faces, num_vertices): every corner unmapped.
    reset(numFaces: i32, numVertices: i32): bool {
        if (numFaces < 0 || numVertices < 0) return false;
        if (numFaces > 0x7FFFFFFF / 3) return false;
        this.cornerToVertex = new Int32Array(numFaces * 3);
        this.cornerToVertex.fill(-1);
        this.oppositeCorners = new Int32Array(numFaces * 3);
        this.oppositeCorners.fill(-1);
        this.vertexCorners = new Int32Array(max<i32>(numVertices, 4));
        this.vertexCount = 0;
        return true;
    }

    numVertices(): i32 { return this.vertexCount; }
    numCorners(): i32 { return this.cornerToVertex.length; }
    numFaces(): i32 { return this.cornerToVertex.length / 3; }

    opposite(corner: i32): i32 {
        if (corner < 0) return corner;
        return this.oppositeCorners[corner];
    }

    vertex(corner: i32): i32 {
        if (corner < 0) return INVALID_INDEX;
        return this.cornerToVertex[corner];
    }

    leftMostCorner(v: i32): i32 { return this.vertexCorners[v]; }

    isOnBoundary(v: i32): bool {
        return this.swingLeft(this.leftMostCorner(v)) == INVALID_INDEX;
    }

    setOppositeCorner(corner: i32, opp: i32): void { this.oppositeCorners[corner] = opp; }

    mapCornerToVertex(corner: i32, v: i32): void { this.cornerToVertex[corner] = v; }

    addNewVertex(): i32 {
        if (this.vertexCount == this.vertexCorners.length) {
            const grown = new Int32Array(this.vertexCorners.length * 2);
            grown.set(this.vertexCorners);
            this.vertexCorners = grown;
        }
        this.vertexCorners[this.vertexCount] = INVALID_INDEX;
        return this.vertexCount++;
    }

    setLeftMostCorner(v: i32, corner: i32): void {
        if (v != INVALID_INDEX) this.vertexCorners[v] = corner;
    }

    makeVertexIsolated(v: i32): void { this.vertexCorners[v] = INVALID_INDEX; }

    isDegenerated(face: i32): bool {
        if (face < 0) return true;
        const c = face * 3;
        const v0 = this.vertex(c), v1 = this.vertex(c + 1), v2 = this.vertex(c + 2);
        return v0 == v1 || v0 == v2 || v1 == v2;
    }
}

/// MeshAttributeCornerTable: the connectivity of one attribute, the mesh's
/// corner table cut along the attribute's seams.
export class MeshAttributeCornerTable extends CornerTableBase {
    isEdgeOnSeam: Uint8Array = new Uint8Array(0);
    isVertexOnSeam: Uint8Array = new Uint8Array(0);
    noInteriorSeams: bool = true;
    cornerToVertexMap: Int32Array = new Int32Array(0);
    vertexToLeftMostCorner: Array<i32> = [];
    vertexToAttributeEntryId: Array<i32> = [];
    cornerTable: CornerTable = new CornerTable();

    initEmpty(table: CornerTable): bool {
        this.isEdgeOnSeam = new Uint8Array(table.numCorners());
        this.isVertexOnSeam = new Uint8Array(table.numVertices());
        this.cornerToVertexMap = new Int32Array(table.numCorners());
        this.cornerToVertexMap.fill(-1);
        this.vertexToLeftMostCorner = [];
        this.vertexToAttributeEntryId = [];
        this.cornerTable = table;
        this.noInteriorSeams = true;
        return true;
    }

    addSeamEdge(c: i32): void {
        const ct = this.cornerTable;
        this.isEdgeOnSeam[c] = 1;
        this.isVertexOnSeam[ct.vertex(ct.next(c))] = 1;
        this.isVertexOnSeam[ct.vertex(ct.previous(c))] = 1;
        const opp = ct.opposite(c);
        if (opp != INVALID_INDEX) {
            this.noInteriorSeams = false;
            this.isEdgeOnSeam[opp] = 1;
            this.isVertexOnSeam[ct.vertex(ct.next(opp))] = 1;
            this.isVertexOnSeam[ct.vertex(ct.previous(opp))] = 1;
        }
    }

    /// RecomputeVertices(nullptr, nullptr): attribute vertices from the seams.
    recomputeVertices(): bool {
        const ct = this.cornerTable;
        this.vertexToAttributeEntryId = [];
        this.vertexToLeftMostCorner = [];
        let numNewVertices = 0;
        const nv = ct.numVertices();
        for (let v = 0; v < nv; ++v) {
            const c = ct.leftMostCorner(v);
            if (c == INVALID_INDEX) continue;
            let firstVertId = numNewVertices++;
            this.vertexToAttributeEntryId.push(firstVertId);
            let firstC = c;
            let actC: i32;
            if (this.isVertexOnSeam[v] != 0) {
                actC = this.swingLeft(firstC);
                while (actC != INVALID_INDEX) {
                    firstC = actC;
                    actC = this.swingLeft(actC);
                    if (actC == c) return false;
                }
            }
            this.cornerToVertexMap[firstC] = firstVertId;
            this.vertexToLeftMostCorner.push(firstC);
            actC = ct.swingRight(firstC);
            while (actC != INVALID_INDEX && actC != firstC) {
                if (this.isEdgeOnSeam[ct.next(actC)] != 0) {
                    firstVertId = numNewVertices++;
                    this.vertexToAttributeEntryId.push(firstVertId);
                    this.vertexToLeftMostCorner.push(actC);
                }
                this.cornerToVertexMap[actC] = firstVertId;
                actC = ct.swingRight(actC);
            }
        }
        return true;
    }

    isCornerOppositeToSeamEdge(corner: i32): bool { return this.isEdgeOnSeam[corner] != 0; }

    isCornerOnSeam(corner: i32): bool {
        return this.isVertexOnSeam[this.cornerTable.vertex(corner)] != 0;
    }

    numVertices(): i32 { return this.vertexToAttributeEntryId.length; }
    numCorners(): i32 { return this.cornerTable.numCorners(); }
    numFaces(): i32 { return this.cornerTable.numFaces(); }

    opposite(corner: i32): i32 {
        if (corner < 0 || this.isEdgeOnSeam[corner] != 0) return INVALID_INDEX;
        return this.cornerTable.opposite(corner);
    }

    vertex(corner: i32): i32 {
        if (corner < 0) return INVALID_INDEX;
        return this.cornerToVertexMap[corner];
    }

    leftMostCorner(v: i32): i32 { return this.vertexToLeftMostCorner[v]; }

    isOnBoundary(v: i32): bool {
        const corner = this.leftMostCorner(v);
        if (corner == INVALID_INDEX) return true;
        return this.swingLeft(corner) == INVALID_INDEX;
    }
}

/// MeshAttributeIndicesEncodingData: the order attribute values were
/// encoded in, and the vertex each one belongs to.
export class MeshAttributeIndicesEncodingData {
    encodedAttributeValueIndexToCornerMap: Array<i32> = [];
    vertexToEncodedAttributeValueIndexMap: Int32Array = new Int32Array(0);
    numValues: i32 = 0;

    init(numVertices: i32): void {
        const m = new Int32Array(numVertices);
        const keep = min<i32>(numVertices, this.vertexToEncodedAttributeValueIndexMap.length);
        for (let i = 0; i < keep; i++) m[i] = this.vertexToEncodedAttributeValueIndexMap[i];
        this.vertexToEncodedAttributeValueIndexMap = m;
    }
}

/// VertexCornersIterator over `table` from `startCorner`: calls back each
/// corner of the vertex (left first, then right from the start). Returns
/// the corners in `out`.
export function vertexCorners(table: CornerTableBase, startCorner: i32, out: Array<i32>): void {
    out.length = 0;
    let corner = startCorner;
    let left = true;
    while (corner != INVALID_INDEX) {
        out.push(corner);
        if (left) {
            corner = table.swingLeft(corner);
            if (corner == INVALID_INDEX) {
                corner = table.swingRight(startCorner);
                left = false;
            } else if (corner == startCorner) {
                corner = INVALID_INDEX;
            }
        } else {
            corner = table.swingRight(corner);
        }
    }
}
