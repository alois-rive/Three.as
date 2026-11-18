// three.js BoxGeometry: six faces, each a group (materialIndex 0..5:
// +x, -x, +y, -y, +z, -z).

import { BufferGeometry } from "../core/BufferGeometry";
import { Float32BufferAttribute } from "../core/BufferAttribute";

export class BoxGeometryParameters {
    width: f64 = 1;
    height: f64 = 1;
    depth: f64 = 1;
    widthSegments: i32 = 1;
    heightSegments: i32 = 1;
    depthSegments: i32 = 1;
}

export class BoxGeometry extends BufferGeometry {
    parameters: BoxGeometryParameters = new BoxGeometryParameters();

    private indices: Array<i32> = [];
    private vertices: Array<f64> = [];
    private normals: Array<f64> = [];
    private uvs: Array<f64> = [];
    private numberOfVertices: i32 = 0;
    private groupStart: i32 = 0;

    constructor(width: f64 = 1, height: f64 = 1, depth: f64 = 1,
                widthSegments: i32 = 1, heightSegments: i32 = 1, depthSegments: i32 = 1) {
        super();
        this.type = "BoxGeometry";
        const p = this.parameters;
        p.width = width; p.height = height; p.depth = depth;
        p.widthSegments = widthSegments; p.heightSegments = heightSegments; p.depthSegments = depthSegments;
        const ws = max<i32>(1, widthSegments), hs = max<i32>(1, heightSegments), ds = max<i32>(1, depthSegments);

        // axis numbers: x 0, y 1, z 2
        this.buildPlane(2, 1, 0, -1, -1, depth, height, width, ds, hs, 0); // px
        this.buildPlane(2, 1, 0, 1, -1, depth, height, -width, ds, hs, 1); // nx
        this.buildPlane(0, 2, 1, 1, 1, width, depth, height, ws, ds, 2); // py
        this.buildPlane(0, 2, 1, 1, -1, width, depth, -height, ws, ds, 3); // ny
        this.buildPlane(0, 1, 2, 1, -1, width, height, depth, ws, hs, 4); // pz
        this.buildPlane(0, 1, 2, -1, -1, width, height, -depth, ws, hs, 5); // nz

        this.setIndex(this.indices);
        this.setAttribute("position", new Float32BufferAttribute(this.vertices, 3));
        this.setAttribute("normal", new Float32BufferAttribute(this.normals, 3));
        this.setAttribute("uv", new Float32BufferAttribute(this.uvs, 2));
        this.indices = [];
        this.vertices = [];
        this.normals = [];
        this.uvs = [];
    }

    private buildPlane(u: i32, v: i32, w: i32, udir: f64, vdir: f64, width: f64, height: f64, depth: f64,
                       gridX: i32, gridY: i32, materialIndex: i32): void {
        const segmentWidth = width / gridX;
        const segmentHeight = height / gridY;
        const widthHalf = width / 2, heightHalf = height / 2, depthHalf = depth / 2;
        const gridX1 = gridX + 1, gridY1 = gridY + 1;
        let vertexCounter = 0;
        let groupCount = 0;
        const vec = new StaticArray<f64>(3);
        for (let iy = 0; iy < gridY1; iy++) {
            const y = <f64>iy * segmentHeight - heightHalf;
            for (let ix = 0; ix < gridX1; ix++) {
                const x = <f64>ix * segmentWidth - widthHalf;
                vec[u] = x * udir; vec[v] = y * vdir; vec[w] = depthHalf;
                this.vertices.push(vec[0]); this.vertices.push(vec[1]); this.vertices.push(vec[2]);
                vec[u] = 0; vec[v] = 0; vec[w] = depth > 0 ? 1 : -1;
                this.normals.push(vec[0]); this.normals.push(vec[1]); this.normals.push(vec[2]);
                this.uvs.push(<f64>ix / <f64>gridX);
                this.uvs.push(1 - <f64>iy / <f64>gridY);
                vertexCounter++;
            }
        }
        const n = this.numberOfVertices;
        for (let iy = 0; iy < gridY; iy++) {
            for (let ix = 0; ix < gridX; ix++) {
                const a = n + ix + gridX1 * iy;
                const b = n + ix + gridX1 * (iy + 1);
                const c = n + (ix + 1) + gridX1 * (iy + 1);
                const d = n + (ix + 1) + gridX1 * iy;
                this.indices.push(a); this.indices.push(b); this.indices.push(d);
                this.indices.push(b); this.indices.push(c); this.indices.push(d);
                groupCount += 6;
            }
        }
        this.addGroup(this.groupStart, groupCount, materialIndex);
        this.groupStart += groupCount;
        this.numberOfVertices += vertexCounter;
    }
}
