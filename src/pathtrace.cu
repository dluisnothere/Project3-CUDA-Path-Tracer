#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/sort.h>
#include <thrust/distance.h>
#include <thrust/partition.h>
#include <thrust/execution_policy.h>
#include <thrust/device_vector.h>
#include <iostream>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#include <device_launch_parameters.h>

#define ERRORCHECK 1
#define SORT_MATERIALS 0
#define CACHE_FIRST_BOUNCE 0 // note that Cache first bounce and antialiasing cannot be on at the same time.
#define ANTIALIASING 0
#define DEPTH_OF_FIELD 0 // depth of field focus defined later
#define DIRECT_LIGHTING 0
#define PERF_ANALYSIS 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)

PerformanceTimer& timer()
{
	static PerformanceTimer timer;
	return timer;
}

void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...
#if CACHE_FIRST_BOUNCE
static ShadeableIntersection* dev_cached_intersections = NULL;
#endif

static Texture* dev_textures = NULL;
static std::vector<cudaArray_t> dev_texData;
static std::vector<cudaTextureObject_t> host_textureObjs;
static cudaTextureObject_t* dev_textureObjs;
static int* dev_textureChannels;

static int numTextures;
static int numGeoms; //cursed variables to cudaFree nested pointers;

static Geom* dev_lights = NULL;

#if PERF_ANALYSIS
static cudaEvent_t beginEvent = NULL;
static cudaEvent_t endEvent = NULL;
#endif

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

// specialized function just to cudaMalloc textures
void createTexture(const Texture &t, int numChannels, int texIdx) {
	// create a channel desc
	cudaChannelFormatDesc channelDesc;

	if (numChannels == 4) {
		channelDesc = cudaCreateChannelDesc<uchar4>();
		checkCUDAError("cudaCreateChannelDesc 4 failed");
	}
	else if (numChannels == 3) {
		channelDesc = cudaCreateChannelDesc<uchar3>();
		checkCUDAError("cudaCreateChannelDesc 3 failed");
	}

	cudaMallocArray(&dev_texData[texIdx], &channelDesc, t.width, t.height);
	checkCUDAError("CudaMallocArray textures failed");

	cudaMemcpyToArray(dev_texData[texIdx], 0, 0, t.host_texData, t.height * t.width * numChannels * sizeof(unsigned char), cudaMemcpyHostToDevice);
	checkCUDAError("CudaMemcpyToArray textures failed");

	struct cudaResourceDesc resDesc;
	memset(&resDesc, 0, sizeof(resDesc));
	resDesc.resType = cudaResourceTypeArray;
	resDesc.res.array.array = dev_texData[texIdx];

	struct cudaTextureDesc texDesc;
	memset(&texDesc, 0, sizeof(texDesc));
	texDesc.addressMode[0] = cudaAddressModeWrap;
	texDesc.addressMode[1] = cudaAddressModeWrap;
	texDesc.filterMode = cudaFilterModeLinear;
	texDesc.readMode = cudaReadModeNormalizedFloat;
	texDesc.normalizedCoords = 1;

	cudaTextureObject_t texObj = 0;
	cudaCreateTextureObject(&texObj, &resDesc, &texDesc, NULL);
	checkCUDAError("Cuda create texture object failed");
	cudaMemcpy(&dev_textureObjs[texIdx], &texObj, sizeof(cudaTextureObject_t), cudaMemcpyHostToDevice);
	checkCUDAError("CudaMemcpy dev_textureObjs failed");
}

void pathtraceInit(Scene* scene) {
	hst_scene = scene;
	numTextures = hst_scene->textures.size();

	numGeoms = hst_scene->geoms.size();

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	checkCUDAError("cudaMalloc dev_image failed");
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));
	checkCUDAError("cudaMemsetd dev_image failed");

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));
	checkCUDAError("cudaMalloc dev_paths failed");

	for (int i = 0; i < scene->geoms.size(); i++) {
		if (scene->geoms[i].numTris > 0) {
			cudaMalloc(&(scene->geoms[i].device_tris), scene->geoms[i].numTris * sizeof(Triangle));
			checkCUDAError("cudaMalloc device_tris failed");
			cudaMemcpy(scene->geoms[i].device_tris, scene->geoms[i].host_tris, scene->geoms[i].numTris * sizeof(Triangle), cudaMemcpyHostToDevice);
			checkCUDAError("cudaMemcpy device_tris failed");
		}
	}

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	checkCUDAError("cudaMalloc dev_geoms failed");
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);
	checkCUDAError("cudaMemcpy gev_geoms failed");

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	checkCUDAError("cudaMalloc dev_materials failed");
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);
	checkCUDAError("cudaMemcpy dev_materials failed");

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	checkCUDAError("cudaMalloc dev_intersections failed");
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));
	checkCUDAError("cudaMemcpy dev_intersectionsf ailed");

#if USE_UV
	cudaMalloc(&dev_textureChannels, scene->textures.size() * sizeof(int));
	checkCUDAError("cudaMalloc dev_textureChannels failed");

	for (int i = 0; i < scene->textures.size(); i++) {
		cudaMemcpy(&dev_textureChannels[i], &scene->textures[i].channels, sizeof(int), cudaMemcpyHostToDevice);
		checkCUDAError("cudaMalloc dev_textureChannels failed");
	}

	cudaMalloc(&dev_textures, scene->textures.size() * sizeof(Texture));
	checkCUDAError("cudaMalloc dev_textures failed");
	cudaMemcpy(dev_textures, scene->textures.data(), scene->textures.size() * sizeof(Texture), cudaMemcpyHostToDevice);
	checkCUDAError("cudaMemcpy dev_textures failed");

	cudaMalloc(&dev_textureObjs, scene->textures.size() * sizeof(cudaTextureObject_t));
	checkCUDAError("cudaMalloc dev_textureObjs ailed");

	dev_texData.resize(scene->textures.size());

	for (int i = 0; i < scene->textures.size(); i++) {
		createTexture(scene->textures[i], scene->textures[i].channels, i);
	}

#endif

#if CACHE_FIRST_BOUNCE
	cudaMalloc(&dev_cached_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_cached_intersections, 0, pixelcount * sizeof(ShadeableIntersection));
#endif

#if DIRECT_LIGHTING
	cudaMalloc(&dev_lights, scene->lights.size() * sizeof(Geom));
	checkCUDAError("cudaMalloc dev_lights failed");
	cudaMemcpy(dev_lights, scene->lights.data(), scene->lights.size() * sizeof(Geom), cudaMemcpyHostToDevice);
	checkCUDAError("cudaMalloc dev_lights failed");
#endif

#if PERF_ANALYSIS
	cudaEventCreate(&beginEvent);
	cudaEventCreate(&endEvent);
#endif

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);

	int numG = numGeoms;
	Geom* tmp_geom_pointer = new Geom[numG];
	cudaMemcpy(tmp_geom_pointer, dev_geoms, numG * sizeof(Geom), cudaMemcpyDeviceToHost);
	for (int i = 0; i < numGeoms; i++) {
		if (tmp_geom_pointer[i].type == OBJ) {
			cudaFree(tmp_geom_pointer[i].device_tris);
			checkCUDAError("cudaFree device_tris failed");
		}
	}

#if USE_UV
	for (int i = 0; i < host_textureObjs.size(); i++) {
		cudaDestroyTextureObject(host_textureObjs[i]);
		cudaFreeArray(dev_texData[i]);
	}
#endif

	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	// TODO: clean up any extra device memory you created

#if DIRECT_LIGHTING
	cudaFree(dev_lights);
#endif

#if PERF_ANALYSIS
	if (beginEvent != NULL) {
		cudaEventDestroy(beginEvent);
	} 
	if (endEvent != NULL) {
		cudaEventDestroy(endEvent);
	}
#endif

	delete[] tmp_geom_pointer;

	checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];

		segment.ray.origin = cam.position;

		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		// TODO: implement antialiasing by jittering the ray
#if (ANTIALIASING && !CACHE_FIRST_BOUNCE)
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
		thrust::uniform_real_distribution<float> u01(0.50, 0.503);

		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * u01(rng))
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * u01(rng))
		);
#else
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
		);
#endif

#if DEPTH_OF_FIELD
#define FOCUS 5.f // focus distance from the camera
#define APERTURE 1.3f // how blurry will out of focus objects be? 

		// if depth of field is turned on, we jitter the ray origin.
		// Calculate the converge point C using ray.origin, ray.direction, and focal length f C = O + f(D)
		// to blur, shift ray origin using using aperture variable and a RNG
		// calculate new ray direction using C - (O - r)
		// shoot multiple secondary rays and average them for pixel. SHOULD ALREADY BE DONE.

		glm::vec3 focalPoint = segment.ray.origin + FOCUS * segment.ray.direction;

		// add blur effect
		thrust::default_random_engine rng2 = makeSeededRandomEngine(iter, index, 0);
		thrust::uniform_real_distribution<float> u02(-0.5, 0.5f);

		float randX = u02(rng2);
		float randY = u02(rng2);
		float randZ = u02(rng2);

		glm::vec3 offset = glm::vec3(randX, randY, randZ);

		segment.ray.origin += APERTURE * offset;
		segment.ray.direction = glm::normalize(focalPoint - segment.ray.origin);

#endif
		segment.pixelIndex = index;

		// debug hard code to 2 instead of traceDepth;
		segment.remainingBounces = traceDepth;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment* pathSegments
	, Geom* geoms
	, int geoms_size
	, ShadeableIntersection* intersections
#if BUMP_MAP
	, cudaTextureObject_t* textureObjs
	, Texture* texs
#endif
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		glm::vec2 uv = glm::vec2(-1, -1);
		bool outside = true;
		bool hitObj; // for use in procedural texturing

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;
		glm::vec2 tmp_uv = glm::vec2(-1, -1);
		bool tmpHitObj = false;

		// naive parse through global geoms

		// test intersection with big obj box and set a boolean for whether triangle should be checked based on this ray.

		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
				tmpHitObj = false;
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
				tmpHitObj = false;
			}
			else if (geom.type == OBJ) {
				float boxT = boundBoxIntersectionTest(&geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
				
				if (boxT != -1) {
					for (int j = 0; j < geom.numTris; j++) {
#if BUMP_MAP
						cudaTextureObject_t texObj = textureObjs[geom.textureid];
						Texture tex = texs[geom.textureid];
						t = triangleIntersectionTest(&geom, &geom.device_tris[j], pathSegment.ray, tmp_intersect, tmp_normal, tmp_uv, texObj, tex, outside);
#else
						t = triangleIntersectionTest(&geom, &geom.device_tris[j], pathSegment.ray, tmp_intersect, tmp_normal, tmp_uv, outside);
#endif
						tmpHitObj = true;

						if (t > 0.0f && t_min > t)
						{
							t_min = t;
							hit_geom_index = i;
							intersect_point = tmp_intersect;
							normal = tmp_normal;
							uv = tmp_uv;
							hitObj = tmpHitObj;
						}
					}
				}
			}
			else if (geom.type == TRIANGLE) {
				// Only use the first triangle, since in Triangle mode, each geom only has 1 triangle
#if BUMP_MAP
				cudaTextureObject_t texObj = textureObjs[geom.textureid];
				Texture tex = texs[geom.textureid];
				t = triangleIntersectionTest(&geom, &geom.device_tris[0], pathSegment.ray, tmp_intersect, tmp_normal, tmp_uv, texObj, tex, outside);
#else
				t = triangleIntersectionTest(&geom, &geom.device_tris[0], pathSegment.ray, tmp_intersect, tmp_normal, tmp_uv, outside);
#endif
				tmpHitObj = true;
			}
			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
				uv = tmp_uv;
				hitObj = tmpHitObj;
			}
		}

		if (hit_geom_index == -1)
		{
			pathSegments[path_index].remainingBounces = 0;
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
			intersections[path_index].uv = uv;
			intersections[path_index].textureId = geoms[hit_geom_index].textureid;
			intersections[path_index].hasHitObj = hitObj;

			pathSegments[path_index].remainingBounces--;
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.

// Di's notes: This code never gets called in the final path tracer
__global__ void shadeFakeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
				pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
				pathSegments[idx].color *= u01(rng); // apply some noise because why not
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.

		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
		}
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

// thrust predicate to end rays that don't hit anything
struct invalid_intersection
{
	__host__ __device__
		bool operator()(const PathSegment& path)
	{
		if (path.remainingBounces)
		{
			return true;
		}
		return false;
	}
};

// thrust predicate to comapre one Intersection
struct path_cmp {
	__host__ __device__
		bool operator()(ShadeableIntersection& inter1, ShadeableIntersection& inter2) {
		return inter1.materialId < inter2.materialId;
	}
};

__global__ void kernComputeShade(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
#if USE_UV
	// , cudaArray_t* textures
	, cudaTextureObject_t* textureObjs
	, int* numChannels
#endif
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);

				// not liking this 
				pathSegments[idx].remainingBounces = 0;
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				// generate new ray and load it into pathSegments by calling scatterRay
				glm::vec3 intersectionPoint = getPointOnRay(pathSegments[idx].ray, intersection.t);
#if USE_UV
				// cudaArray_t texture = textures[intersection.textureId];
				cudaTextureObject_t texObj = textureObjs[intersection.textureId];
				int channels = numChannels[intersection.textureId];
				scatterRay(pathSegments[idx], intersectionPoint, intersection.surfaceNormal, intersection.textureId, intersection.uv, material, /*texture,*/ texObj, channels, rng);

#elif USE_PROCEDURAL_TEXTURE		
				scatterRay(pathSegments[idx], intersectionPoint, intersection.surfaceNormal, material, rng, intersection.hasHitObj);
#else
				scatterRay(pathSegments[idx], intersectionPoint, intersection.surfaceNormal, material, rng);
#endif
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
		}
	}
}

#if DIRECT_LIGHTING
__global__ void kernComputeShadeDirectLighting(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
	, Geom* lights
	, int numLights
#if USE_UV
	, cudaTextureObject_t* textureObjs
	, int* numChannels
#endif
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);

				// not liking this 
				pathSegments[idx].remainingBounces = 0;
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				// generate new ray and load it into pathSegments by calling scatterRay
				glm::vec3 intersectionPoint = getPointOnRay(pathSegments[idx].ray, intersection.t);
#if USE_UV
				// cudaArray_t texture = textures[intersection.textureId];
				cudaTextureObject_t texObj = textureObjs[intersection.textureId];
				int channels = numChannels[intersection.textureId];
				scatterRay(pathSegments[idx], intersectionPoint, intersection.surfaceNormal, intersection.textureId, intersection.uv, material, /*texture,*/ texObj, channels, rng);

#elif USE_PROCEDURAL_TEXTURE		
				scatterRay(pathSegments[idx], intersectionPoint, intersection.surfaceNormal, material, rng, intersection.hasHitObj);
#else
				scatterRay(pathSegments[idx], intersectionPoint, intersection.surfaceNormal, material, rng);
#endif
			}

			if (pathSegments[idx].remainingBounces == 1) {
				// randomly choose light from 0 to numLights
				thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
				thrust::uniform_real_distribution<int> u02(0, numLights);
				int randLightIdx = u02(rng);
				Geom currLight = lights[randLightIdx];
				// randomly choose location on light
				thrust::uniform_real_distribution<float> u03(0, 1);
				float randX = u03(rng);
				float randY = u03(rng);
				float randZ = u03(rng);

				glm::vec3 lightSpot = glm::vec3(currLight.transform * glm::vec4(randX, randY, randZ, 1.f));

				pathSegments[idx].ray.direction = glm::normalize(lightSpot - pathSegments[idx].ray.origin);
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
		}
	}
}
#endif

// if cache
#if CACHE_FIRST_BOUNCE
/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;

	int currNumPaths = num_paths;

	while (!iterationComplete) {
		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (currNumPaths + blockSize1d - 1) / blockSize1d;

		if (iter == 1 && depth == 0) {
			// load cached intersections into dev_intersections
			cudaMemcpy(dev_intersections, dev_cached_intersections, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
		}
		else {
			// otherwise, continue as usual with dev_intersections
#if BUMP_MAP
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, currNumPaths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				, dev_textureObjs
				, dev_textures
				);
			checkCUDAError("trace one bounce");
#else
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, currNumPaths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				);
			checkCUDAError("trace one bounce");
#endif
		}

		cudaDeviceSynchronize();

		depth++;

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
		// evaluating the BSDF.
		// Start off with just a big kernel that handles all the different
		// materials you have in the scenefile.
		// TODO: compare between directly shading the path segments and shading
		// path segments that have been reshuffled to be contiguous in memory.

		// 1. sort pathSegments by material type
		// This becomes very slow?
#if SORT_MATERIALS
		thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + currNumPaths, dev_paths, path_cmp());
#endif	
		// 2. shade the ray and spawn new path segments using BSDF
		// this function generates a new ray to replace the old one using BSDF
#if DIRECT_LIGHTING
		kernComputeShadeDirectLighting << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			currNumPaths,
			dev_intersections,
			dev_paths,
			dev_materials,
			dev_lights,
			hst_scene->numLights
#if USE_UV
			, dev_textureObjs
			, dev_textureChannels
#endif
			);
#else 
		kernComputeShade << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			currNumPaths,
			dev_intersections,
			dev_paths,
			dev_materials
#if USE_UV
			, dev_textureObjs
			, dev_textureChannels
#endif
			);
#endif

		cudaDeviceSynchronize();

		// 4. remove_if sorts all contents such that useless paths are all at the end.
		// if the remainingBounces = 0 (any material that doesn't hit anything or number of depth is at its limit)
		dev_path_end = thrust::stable_partition(thrust::device, dev_paths, dev_paths + currNumPaths, invalid_intersection());

		// nothing shows up if i set it out side of the if/else statement.
		currNumPaths = dev_path_end - dev_paths;

		// don't need to remove intersections because new intersections will be computed based on sorted dev_paths
		// thrust uses exclusive start and end pointers, so if end pointer is the same as start pointer, we have no rays left.
		if (currNumPaths < 1)
		{
			iterationComplete = true;
		}

		if (iter == 0 && depth == 0) {
			cudaMemcpy(dev_cached_intersections, dev_intersections, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
		}

		if (guiData != NULL)
		{
			guiData->TracedDepth = depth;
		}
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (num_paths, dev_image, dev_paths);

	cudaDeviceSynchronize(); // maybe dont need

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	cudaDeviceSynchronize(); // maybe dont need

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}

#else
// If not cache intersections
/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;

	int currNumPaths = num_paths;

#if PERF_ANALYSIS
	cudaEventRecord(beginEvent);
#endif

	while (!iterationComplete) {
		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (currNumPaths + blockSize1d - 1) / blockSize1d;
#if BUMP_MAP
		computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth
			, currNumPaths
			, dev_paths
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_intersections
			, dev_textureObjs
			, dev_textures
			);
		checkCUDAError("trace one bounce");
#else
		computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth
			, currNumPaths
			, dev_paths
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_intersections
			);
		checkCUDAError("trace one bounce");
#endif
		cudaDeviceSynchronize();

		depth++;

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
		// evaluating the BSDF.
		// Start off with just a big kernel that handles all the different
		// materials you have in the scenefile.
		// TODO: compare between directly shading the path segments and shading
		// path segments that have been reshuffled to be contiguous in memory.

		// 1. sort pathSegments by material type
		// This becomes very slow?
#if SORT_MATERIALS
		thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + currNumPaths, dev_paths, path_cmp());
#endif	
		// 2. shade the ray and spawn new path segments using BSDF
		// this function generates a new ray to replace the old one using BSDF
#if DIRECT_LIGHTING
		kernComputeShadeDirectLighting << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			currNumPaths,
			dev_intersections,
			dev_paths,
			dev_materials,
			dev_lights,
			hst_scene->numLights
#if USE_UV
			, dev_textureObjs
			, dev_textureChannels
#endif
			);
#else 
		kernComputeShade << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			currNumPaths,
			dev_intersections,
			dev_paths,
			dev_materials
#if USE_UV
			, dev_textureObjs
			, dev_textureChannels
#endif
			);
#endif

		cudaDeviceSynchronize();

		// 4. remove_if sorts all contents such that useless paths are all at the end.
		// if the remainingBounces = 0 (any material that doesn't hit anything or number of depth is at its limit)
		dev_path_end = thrust::stable_partition(thrust::device, dev_paths, dev_paths + currNumPaths, invalid_intersection());

		// nothing shows up if i set it out side of the if/else statement.
		currNumPaths = dev_path_end - dev_paths;
		// printf("curNum Paths: %i \n", currNumPaths);

		// don't need to remove intersections because new intersections will be computed based on sorted dev_paths
		// thrust uses exclusive start and end pointers, so if end pointer is the same as start pointer, we have no rays left.
		if (currNumPaths < 1)
		{
			iterationComplete = true;
		}

		if (guiData != NULL)
		{
			guiData->TracedDepth = depth;
		}
	}

#if PERF_ANALYSIS
	cudaEventRecord(endEvent);
	cudaEventSynchronize(endEvent);

	float time; // in ms

	cudaEventElapsedTime(&time, beginEvent, endEvent);
	printf("time: %f, iter: %i \n", time, iter);
#endif

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (num_paths, dev_image, dev_paths);

	cudaDeviceSynchronize(); // maybe dont need

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	cudaDeviceSynchronize(); // maybe dont need

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}
#endif