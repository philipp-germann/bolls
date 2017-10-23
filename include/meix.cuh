// Handle closed surface meshes for image-based models
#pragma once

#include <assert.h>
#include <math.h>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "dtypes.cuh"
#include "solvers.cuh"
#include "utils.cuh"


struct Ray {
    float3 P0;
    float3 P1;
    Ray(float3 a, float3 b)
    {
        P0 = a;
        P1 = b;
    }
};


struct Triangle {
    float3 V0;
    float3 V1;
    float3 V2;
    float3 C;
    float3 n;
    Triangle() : Triangle(float3{0}, float3{0}, float3{0}) {}
    Triangle(float3 a, float3 b, float3 c)
    {
        V0 = a;
        V1 = b;
        V2 = c;
        calculate_centroid();
        calculate_normal();
    }
    void calculate_centroid() { C = (V0 + V1 + V2) / 3.f; }
    void calculate_normal()
    {
        auto v = V2 - V0;
        auto u = V1 - V0;
        n = float3{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z,
            u.x * v.y - u.y * v.x};
        n /= sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    }
};


class Meix {
public:
    float surf_area;
    int n_vertices;
    int n_facets;
    std::vector<float3> vertices;
    std::vector<Triangle> facets;
    int* d_n_vertices;
    int* d_n_facets;
    float3* d_vertices;
    float3* d_facets;
    int** triangle_to_vertices;
    std::vector<std::vector<int>> vertex_to_triangles;
    Meix();
    Meix(std::string file_name);
    Meix(const Meix& copy);
    Meix& operator=(const Meix& other);
    float3 get_minimum();
    float3 get_maximum();
    void translate(float3 offset);
    void rotate(float around_z, float around_y, float around_x);
    void rescale(float factor);
    void grow_normally(float amount, bool boundary);
    template<typename Pt>
    bool test_exclusion(const Pt boll);
    void write_vtk(std::string);
    void copy_to_device();
    template<typename Pt, int n_max, template<typename, int> class Solver>
    float shape_comparison_distance_meix_to_bolls(Solution<Pt, n_max,
        Solver>& bolls);
    template<typename Pt, int n_max, template<typename, int> class Solver>
    float shape_comparison_distance_bolls_to_bolls(Solution<Pt, n_max,
        Solver>& bolls1, Solution<Pt, n_max, Solver>& bolls2);
    ~Meix();
};

Meix::Meix()
{
    surf_area = 0.f;
    n_vertices = 0;
    n_facets = 0;
    triangle_to_vertices = NULL;
}

Meix::Meix(std::string file_name)
{
    surf_area = 0.f;  // initialise

    std::string line;
    std::ifstream input_file;
    std::vector<std::string> items;

    input_file.open(file_name, std::fstream::in);
    assert(input_file.is_open());

    auto points_start = false;
    do {
        getline(input_file, line);
        items = split(line);
        if (items.size() > 0)
            points_start = items[0] == "POINTS";
    } while (!points_start);
    n_vertices = stoi(items[1]);

    // Read vertices
    auto count = 0;
    while (count < n_vertices) {
        getline(input_file, line);
        items = split(line);

        auto n_points = items.size() / 3;
        for (auto i = 0; i < n_points; i++) {
            float3 P;
            P.x = stof(items[i * 3]);
            P.y = stof(items[i * 3 + 1]);
            P.z = stof(items[i * 3 + 2]);
            vertices.push_back(P);
            count++;
        }
    }

    // Read facets
    auto polygon_start = false;
    do {
        getline(input_file, line);
        items = split(line);
        if (items.size() > 0)
            polygon_start = items[0] == "POLYGONS" or items[0] == "CELLS";
    } while (!polygon_start);
    n_facets = stoi(items[1]);
    assert(n_facets % 2 == 0);  // Otherwise mesh cannot be closed

    triangle_to_vertices = (int**)malloc(n_facets * sizeof(int*));
    for (auto i = 0; i < n_facets; i++)
        triangle_to_vertices[i] = (int*)malloc(3 * sizeof(int));

    for (auto i = 0; i < n_facets; i++) {
        getline(input_file, line);
        items = split(line);
        triangle_to_vertices[i][0] = stoi(items[1]);
        triangle_to_vertices[i][1] = stoi(items[2]);
        triangle_to_vertices[i][2] = stoi(items[3]);
        Triangle T(vertices[stoi(items[1])], vertices[stoi(items[2])],
            vertices[stoi(items[3])]);
        facets.push_back(T);
    }

    // Construct the vector of triangles adjacent to each vertex
    std::vector<int> empty;
    std::vector<std::vector<int>> dummy(n_vertices, empty);
    vertex_to_triangles = dummy;

    int vertex;
    for (auto i = 0; i < n_facets; i++) {
        vertex = triangle_to_vertices[i][0];
        vertex_to_triangles[vertex].push_back(i);
        vertex = triangle_to_vertices[i][1];
        vertex_to_triangles[vertex].push_back(i);
        vertex = triangle_to_vertices[i][2];
        vertex_to_triangles[vertex].push_back(i);
    }
}

Meix::Meix(const Meix& copy)
{
    surf_area = 0.f;
    n_vertices = copy.n_vertices;
    n_facets = copy.n_facets;
    vertices = copy.vertices;
    facets = copy.facets;

    triangle_to_vertices = (int**)malloc(n_facets * sizeof(int*));
    for (int i = 0; i < n_facets; i++) {
        triangle_to_vertices[i] = (int*)malloc(3 * sizeof(int));
        memcpy(triangle_to_vertices[i], copy.triangle_to_vertices[i],
            sizeof(int) * 3);
    }

    std::vector<int> empty;
    std::vector<std::vector<int>> dummy(n_vertices, empty);
    vertex_to_triangles = dummy;
    for (int i = 0; i < n_vertices; i++)
        vertex_to_triangles[i] = copy.vertex_to_triangles[i];
}

Meix& Meix::operator=(const Meix& other)
{
    surf_area = 0.f;
    n_vertices = other.n_vertices;
    n_facets = other.n_facets;
    vertices = other.vertices;
    facets = other.facets;
    triangle_to_vertices = (int**)malloc(n_facets * sizeof(int*));
    for (int i = 0; i < n_facets; i++) {
        triangle_to_vertices[i] = (int*)malloc(3 * sizeof(int));
        memcpy(triangle_to_vertices[i], other.triangle_to_vertices[i],
            sizeof(int) * 3);
    }
    std::vector<int> empty;
    std::vector<std::vector<int>> dummy(n_vertices, empty);
    vertex_to_triangles = dummy;
    for (int i = 0; i < n_vertices; i++)
        vertex_to_triangles[i] = other.vertex_to_triangles[i];

    return *this;
}

float3 Meix::get_minimum()
{
    float3 minimum{vertices[0].x, vertices[0].y, vertices[0].z};
    for (auto i = 1; i < n_vertices; i++) {
        minimum.x = min(minimum.x, vertices[i].x);
        minimum.y = min(minimum.y, vertices[i].y);
        minimum.z = min(minimum.z, vertices[i].z);
    }
    return minimum;
}

float3 Meix::get_maximum()
{
    float3 maximum{vertices[0].x, vertices[0].y, vertices[0].z};
    for (auto i = 1; i < n_vertices; i++) {
        maximum.x = max(maximum.x, vertices[i].x);
        maximum.y = max(maximum.y, vertices[i].y);
        maximum.z = max(maximum.z, vertices[i].z);
    }
    return maximum;
}

void Meix::translate(float3 offset)
{
    for (int i = 0; i < n_vertices; i++) {
        vertices[i] = vertices[i] + offset;
    }

    for (int i = 0; i < n_facets; i++) {
        facets[i].V0 = facets[i].V0 + offset;
        facets[i].V1 = facets[i].V1 + offset;
        facets[i].V2 = facets[i].V2 + offset;
        facets[i].C = facets[i].C + offset;
    }
}

void Meix::rotate(float around_z, float around_y, float around_x)
{
    for (int i = 0; i < n_facets; i++) {
        float3 old = facets[i].V0;
        facets[i].V0.x = old.x * cos(around_z) - old.y * sin(around_z);
        facets[i].V0.y = old.x * sin(around_z) + old.y * cos(around_z);

        old = facets[i].V1;
        facets[i].V1.x = old.x * cos(around_z) - old.y * sin(around_z);
        facets[i].V1.y = old.x * sin(around_z) + old.y * cos(around_z);

        old = facets[i].V2;
        facets[i].V2.x = old.x * cos(around_z) - old.y * sin(around_z);
        facets[i].V2.y = old.x * sin(around_z) + old.y * cos(around_z);

        old = facets[i].C;
        facets[i].C.x = old.x * cos(around_z) - old.y * sin(around_z);
        facets[i].C.y = old.x * sin(around_z) + old.y * cos(around_z);

        facets[i].calculate_normal();
    }
    for (int i = 0; i < n_vertices; i++) {
        float3 old = vertices[i];
        vertices[i].x = old.x * cos(around_z) - old.y * sin(around_z);
        vertices[i].y = old.x * sin(around_z) + old.y * cos(around_z);
    }

    for (int i = 0; i < n_facets; i++) {
        float3 old = facets[i].V0;
        facets[i].V0.x = old.x * cos(around_y) - old.z * sin(around_y);
        facets[i].V0.z = old.x * sin(around_y) + old.z * cos(around_y);

        old = facets[i].V1;
        facets[i].V1.x = old.x * cos(around_y) - old.z * sin(around_y);
        facets[i].V1.z = old.x * sin(around_y) + old.z * cos(around_y);

        old = facets[i].V2;
        facets[i].V2.x = old.x * cos(around_y) - old.z * sin(around_y);
        facets[i].V2.z = old.x * sin(around_y) + old.z * cos(around_y);

        old = facets[i].C;
        facets[i].C.x = old.x * cos(around_y) - old.z * sin(around_y);
        facets[i].C.z = old.x * sin(around_y) + old.z * cos(around_y);

        facets[i].calculate_normal();
    }
    for (int i = 0; i < n_vertices; i++) {
        float3 old = vertices[i];
        vertices[i].x = old.x * cos(around_y) - old.z * sin(around_y);
        vertices[i].z = old.x * sin(around_y) + old.z * cos(around_y);
    }

    for (int i = 0; i < n_facets; i++) {
        float3 old = facets[i].V0;
        facets[i].V0.y = old.y * cos(around_x) - old.z * sin(around_x);
        facets[i].V0.z = old.y * sin(around_x) + old.z * cos(around_x);

        old = facets[i].V1;
        facets[i].V1.y = old.y * cos(around_x) - old.z * sin(around_x);
        facets[i].V1.z = old.y * sin(around_x) + old.z * cos(around_x);

        old = facets[i].V2;
        facets[i].V2.y = old.y * cos(around_x) - old.z * sin(around_x);
        facets[i].V2.z = old.y * sin(around_x) + old.z * cos(around_x);

        old = facets[i].C;
        facets[i].C.y = old.y * cos(around_x) - old.z * sin(around_x);
        facets[i].C.z = old.y * sin(around_x) + old.z * cos(around_x);

        facets[i].calculate_normal();
    }
    for (int i = 0; i < n_vertices; i++) {
        float3 old = vertices[i];
        vertices[i].y = old.y * cos(around_x) - old.z * sin(around_x);
        vertices[i].z = old.y * sin(around_x) + old.z * cos(around_x);
    }
}

void Meix::rescale(float factor)
{
    for (int i = 0; i < n_vertices; i++) {
        vertices[i] = vertices[i] * factor;
    }

    for (int i = 0; i < n_facets; i++) {
        facets[i].V0 = facets[i].V0 * factor;
        facets[i].V1 = facets[i].V1 * factor;
        facets[i].V2 = facets[i].V2 * factor;
        facets[i].C = facets[i].C * factor;
    }
}

void Meix::grow_normally(float amount, bool boundary = false)
{
    for (int i = 0; i < n_vertices; i++) {
        if (boundary && vertices[i].x == 0.f) continue;

        float3 average_normal{0};
        for (int j = 0; j < vertex_to_triangles[i].size(); j++) {
            int triangle = vertex_to_triangles[i][j];
            average_normal = average_normal + facets[triangle].n;
        }

        float d = sqrt(pow(average_normal.x, 2) + pow(average_normal.y, 2) +
                       pow(average_normal.z, 2));
        average_normal = average_normal * (amount / d);

        vertices[i] = vertices[i] + average_normal;
    }

    for (int i = 0; i < n_facets; i++) {
        int V0 = triangle_to_vertices[i][0];
        int V1 = triangle_to_vertices[i][1];
        int V2 = triangle_to_vertices[i][2];
        facets[i].V0 = vertices[V0];
        facets[i].V1 = vertices[V1];
        facets[i].V2 = vertices[V2];
        facets[i].calculate_centroid();
        facets[i].calculate_normal();
    }
}

template<typename Pt_a, typename Pt_b>
float scalar_product(Pt_a a, Pt_b b)
{
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

// Theory and algorithm: http://geomalgorithms.com/a06-_intersect-2.html
bool intersect(Ray R, Triangle T)
{
    // Find intersection point PI
    auto r =
        scalar_product(T.n, T.V0 - R.P0) / scalar_product(T.n, R.P1 - R.P0);
    if (r < 0) return false;  // Ray going away

    auto PI = R.P0 + ((R.P1 - R.P0) * r);

    // Check if PI in T
    auto u = T.V1 - T.V0;
    auto v = T.V2 - T.V0;
    auto w = PI - T.V0;
    auto uu = scalar_product(u, u);
    auto uv = scalar_product(u, v);
    auto vv = scalar_product(v, v);
    auto wu = scalar_product(w, u);
    auto wv = scalar_product(w, v);
    auto denom = uv * uv - uu * vv;

    auto s = (uv * wv - vv * wu) / denom;
    if (s < 0.0 or s > 1.0) return false;

    auto t = (uv * wu - uu * wv) / denom;
    if (t < 0.0 or (s + t) > 1.0) return false;

    return true;
}

template<typename Pt>
bool Meix::test_exclusion(const Pt boll)
{
    auto p_0 = float3{boll.x, boll.y, boll.z};
    auto p_1 = p_0 + float3{0.22788, 0.38849, 0.81499};
    Ray R(p_0, p_1);
    int n_intersections = 0;
    for (int j = 0; j < n_facets; j++) {
        n_intersections += intersect(R, facets[j]);
    }
    return (n_intersections % 2 == 0);
}

void Meix::write_vtk(std::string output_tag)
{
    std::string filename = "output/" + output_tag + ".meix.vtk";
    std::ofstream meix_file(filename);
    assert(meix_file.is_open());

    meix_file << "# vtk DataFile Version 3.0\n";
    meix_file << output_tag + ".meix"
              << "\n";
    meix_file << "ASCII\n";
    meix_file << "DATASET POLYDATA\n";

    meix_file << "\nPOINTS " << 3 * n_facets << " float\n";
    for (auto i = 0; i < n_facets; i++) {
        meix_file << facets[i].V0.x << " " << facets[i].V0.y << " "
                  << facets[i].V0.z << "\n";
        meix_file << facets[i].V1.x << " " << facets[i].V1.y << " "
                  << facets[i].V1.z << "\n";
        meix_file << facets[i].V2.x << " " << facets[i].V2.y << " "
                  << facets[i].V2.z << "\n";
    }

    meix_file << "\nPOLYGONS " << n_facets << " " << 4 * n_facets << "\n";
    for (auto i = 0; i < 3 * n_facets; i += 3) {
        meix_file << "3 " << i << " " << i + 1 << " " << i + 2 << "\n";
    }
    meix_file.close();
}

void Meix::copy_to_device()
{
    cudaMalloc(&d_n_vertices, sizeof(int));
    cudaMalloc(&d_vertices, n_vertices * sizeof(float3));

    float3* h_vert = (float3*)malloc(n_vertices * sizeof(float3));
    for(int i = 0; i < n_vertices; i++)
        h_vert[i] = vertices[i];

    cudaMemcpy(d_n_vertices, &n_vertices, sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_vertices, h_vert, n_vertices * sizeof(float3),
        cudaMemcpyHostToDevice);

    cudaMalloc(&d_n_facets, sizeof(int));
    cudaMalloc(&d_facets, n_facets * sizeof(float3));
    float3* h_tri = (float3*)malloc(n_facets * sizeof(float3));
    for(int i = 0; i < n_facets; i++)
        h_tri[i] = facets[i].C;

    cudaMemcpy(d_n_facets, &n_facets, sizeof(int), cudaMemcpyHostToDevice);
    cudaMemcpy(d_facets, h_tri, n_facets * sizeof(float3),
        cudaMemcpyHostToDevice);
}

// Compute pairwise interactions and frictions one thread per point, to
// TILE_SIZE points at a time, after http://http.developer.nvidia.com/
// GPUGems3/gpugems3_ch31.html.
template<typename Pt>
__global__ void calculate_minimum_distance_meix_to_bolls(const int n_bolls,
    const int n_meix, const Pt* __restrict__ d_X_bolls, float3* d_X_meix,
    float* d_min_dist, bool bolls_to_meix)
{
    auto i = blockIdx.x * blockDim.x + threadIdx.x;

    if(bolls_to_meix){
        __shared__ float3 shX[TILE_SIZE];
        Pt Xi{0};
        if (i < n_bolls) Xi = d_X_bolls[i];
        float min_dist = 10000.f;
        for (auto tile_start = 0; tile_start < n_meix;
            tile_start += TILE_SIZE) {
            auto j = tile_start + threadIdx.x;
            if (j < n_meix) {
                shX[threadIdx.x] = d_X_meix[j];
            }
            __syncthreads();

            for (auto k = 0; k < TILE_SIZE; k++) {
                auto j = tile_start + k;
                if ((i < n_bolls) and (j < n_meix)) {
                    float3 r{Xi.x - shX[k].x, Xi.y - shX[k].y, Xi.z- shX[k].z};
                    auto dist = norm3df(r.x, r.y, r.z);
                    if(dist < min_dist)
                        min_dist = dist;
                }
            }
        }
        if (i < n_bolls)
            d_min_dist[i] = min_dist;
    } else { // meix to bolls
        __shared__ float3 shX[TILE_SIZE];
        Pt Xi{0};
        if (i < n_meix) Xi = d_X_meix[i];
        float min_dist = 10000.f;
        for (auto tile_start = 0; tile_start < n_bolls;
                tile_start += TILE_SIZE) {
            auto j = tile_start + threadIdx.x;
            if (j < n_bolls) {
                shX[threadIdx.x] = d_X_bolls[j];
            }
            __syncthreads();

            for (auto k = 0; k < TILE_SIZE; k++) {
                auto j = tile_start + k;
                if ((i < n_meix) and (j < n_bolls)) {
                    float3 r{Xi.x - shX[k].x, Xi.y - shX[k].y, Xi.z- shX[k].z};
                    auto dist = norm3df(r.x, r.y, r.z);
                    if(dist < min_dist)
                        min_dist = dist;
                }
            }
        }
        if (i < n_meix)
            d_min_dist[i] = min_dist;
    }

}

template<typename Pt, int n_max, template<typename, int> class Solver>
float Meix::shape_comparison_distance_meix_to_bolls(Solution<Pt, n_max,
    Solver>& bolls)
{
    auto n_bolls = bolls.get_d_n();

    float* d_meix_dist;
    cudaMalloc(&d_meix_dist, n_vertices * sizeof(float));
    float* h_meix_dist = (float*)malloc(n_vertices * sizeof(float));

    calculate_minimum_distance_meix_to_bolls<<<(n_vertices + TILE_SIZE - 1) /
        TILE_SIZE, TILE_SIZE>>>(n_bolls, n_vertices,
        bolls.d_X, d_vertices, d_meix_dist, false);
    cudaMemcpy(h_meix_dist, d_meix_dist, n_vertices * sizeof(float),
        cudaMemcpyDeviceToHost);

    auto distance = 0.0f;
    for(int i = 0; i < n_vertices; i++)
        distance += h_meix_dist[i];

    float* d_bolls_dist;
    cudaMalloc(&d_bolls_dist, *bolls.h_n * sizeof(float));
    float* h_bolls_dist = (float*)malloc(n_bolls * sizeof(float));
    calculate_minimum_distance_meix_to_bolls<<<(n_bolls + TILE_SIZE - 1) /
        TILE_SIZE, TILE_SIZE>>>(n_bolls, n_vertices,
        bolls.d_X, d_vertices, d_bolls_dist, true);
    cudaMemcpy(h_bolls_dist, d_bolls_dist, n_bolls * sizeof(float),
        cudaMemcpyDeviceToHost);

    for(int i = 0; i < n_bolls; i++)
        distance += h_bolls_dist[i];

    return distance / (n_vertices + n_bolls);
}

template<typename Pt>
__global__ void calculate_minimum_distance_bolls_to_bolls(const int n_bolls1,
        const int n_bolls2, const Pt* __restrict__ d_X_bolls1, Pt* d_X_bolls2,
        float* d_min_dist)
{
    auto i = blockIdx.x * blockDim.x + threadIdx.x;

    __shared__ float3 shX[TILE_SIZE];
    Pt Xi{0};
    if (i < n_bolls1) Xi = d_X_bolls1[i];
    float min_dist = 10000.f;
    for (auto tile_start = 0; tile_start < n_bolls2; tile_start += TILE_SIZE) {
        auto j = tile_start + threadIdx.x;
        if (j < n_bolls2) {
            shX[threadIdx.x] = d_X_bolls2[j];
        }
        __syncthreads();

        for (auto k = 0; k < TILE_SIZE; k++) {
            auto j = tile_start + k;
            if ((i < n_bolls1) and (j < n_bolls2)) {
                float3 r{Xi.x - shX[k].x, Xi.y - shX[k].y, Xi.z- shX[k].z};
                auto dist = norm3df(r.x, r.y, r.z);
                if(dist < min_dist)
                    min_dist = dist;
            }
        }
    }
    if (i < n_bolls1)
        d_min_dist[i] = min_dist;
}

template<typename Pt, int n_max, template<typename, int> class Solver>
float Meix::shape_comparison_distance_bolls_to_bolls(Solution<Pt, n_max,
    Solver>& bolls1, Solution<Pt, n_max, Solver>& bolls2)
{
    auto n_bolls1 = bolls1.get_d_n();
    auto n_bolls2 = bolls2.get_d_n();

    float* d_12_dist;
    cudaMalloc(&d_12_dist, n_bolls1 * sizeof(float));
    float* h_12_dist = (float*)malloc(n_bolls1 * sizeof(float));

    calculate_minimum_distance_bolls_to_bolls<<<(n_bolls1 + TILE_SIZE - 1) /
        TILE_SIZE, TILE_SIZE>>>(n_bolls1, n_bolls2,
        bolls1.d_X, bolls2.d_X, d_12_dist);
    cudaMemcpy(h_12_dist, d_12_dist, n_bolls1 * sizeof(float),
        cudaMemcpyDeviceToHost);

    auto distance = 0.0f;
    for(int i = 0; i < n_bolls1; i++)
        distance += h_12_dist[i];

    float* d_21_dist;
    cudaMalloc(&d_21_dist, n_bolls2 * sizeof(float));
    float* h_21_dist = (float*)malloc(n_bolls2 * sizeof(float));
    calculate_minimum_distance_bolls_to_bolls<<<(n_bolls2 + TILE_SIZE - 1) /
        TILE_SIZE, TILE_SIZE>>>(n_bolls2, n_bolls1,
        bolls2.d_X, bolls1.d_X, d_21_dist);
    cudaMemcpy(h_21_dist, d_21_dist, n_bolls2 * sizeof(float),
        cudaMemcpyDeviceToHost);

    for(int i = 0; i < n_bolls2; i++)
        distance += h_21_dist[i];

    return distance / (n_bolls1 + n_bolls2);
}

Meix::~Meix()
{
    vertices.clear();
    facets.clear();

    if (triangle_to_vertices != NULL) {
        for (int i = 0; i < n_facets; i++) {
            free(triangle_to_vertices[i]);
        }
        free(triangle_to_vertices);
    }

    for (int i = 0; i < vertex_to_triangles.size(); i++)
        vertex_to_triangles[i].clear();

    vertex_to_triangles.clear();
}
