// CIS565 CUDA Rasterizer: A simple rasterization pipeline for Patrick Cozzi's CIS565: GPU Computing at the University of Pennsylvania
// Written by Yining Karl Li, Copyright (c) 2012 University of Pennsylvania

#include "rasterizeKernels.h"
#include "rasterizeTools.h"


glm::vec3* framebuffer;
fragment* depthbuffer;
float* device_vbo;
float* device_nbo;
float* device_cbo;
int* device_ibo;
vertex* verticies;
triangle* primitives;
int* primitiveStageBuffer;
uniforms* device_uniforms;

int* binBuffers;
int* bufferCounters;

void checkCUDAError(const char *msg) {
	cudaError_t err = cudaGetLastError();
	if( cudaSuccess != err) {
		fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString( err) ); 
		exit(EXIT_FAILURE); 
	}
} 

//Handy dandy little hashing function that provides seeds for random number generation
__host__ __device__ unsigned int hash(unsigned int a){
	a = (a+0x7ed55d16) + (a<<12);
	a = (a^0xc761c23c) ^ (a>>19);
	a = (a+0x165667b1) + (a<<5);
	a = (a+0xd3a2646c) ^ (a<<9);
	a = (a+0xfd7046c5) + (a<<3);
	a = (a^0xb55a4f09) ^ (a>>16);
	return a;
}


//Writes a given fragment to a fragment buffer at a given location
__host__ __device__ void writeToDepthbuffer(int x, int y, fragment frag, fragment* depthbuffer, glm::vec2 resolution){
	if(x<resolution.x && y<resolution.y){
		int index = (y*resolution.x) + x;
		depthbuffer[index] = frag;
	}
}

//Reads a fragment from a given location in a fragment buffer
__host__ __device__ fragment getFromDepthbuffer(int x, int y, fragment* depthbuffer, glm::vec2 resolution){
	if(x<resolution.x && y<resolution.y){
		int index = (y*resolution.x) + x;
		return depthbuffer[index];
	}else{
		fragment f;
		return f;
	}
}

__host__ __device__ int getDepthBufferIndex(int x, int y, glm::vec2 resolution){
	if(x<resolution.x && y<resolution.y && x>=0 && y >= 0)
		return (y*resolution.x) + x;

	return -1;
}

__host__ __device__ float getDepthFromDepthbuffer(int x, int y, fragment* depthbuffer, glm::vec2 resolution){
	if(x<resolution.x && y<resolution.y){
		int index = (y*resolution.x) + x;
		return depthbuffer[index].depth;
	}else{
		return 0;
	}
}

__device__ unsigned long long int fatomicMin(unsigned long long int  * addr, unsigned long long int value)
{
	unsigned long long ret = *addr;
	while(value < ret)
	{
		unsigned long long old = ret;
		if((ret = atomicCAS(addr, old, value)) == old)
			break;
	}
	return ret;

}

//Writes a given pixel to a pixel buffer at a given location
__host__ __device__ void writeToFramebuffer(int x, int y, glm::vec3 value, glm::vec3* framebuffer, glm::vec2 resolution){
	if(x<resolution.x && y<resolution.y){
		int index = (y*resolution.x) + x;
		framebuffer[index] = value;
	}
}

//Reads a pixel from a pixel buffer at a given location
__host__ __device__ glm::vec3 getFromFramebuffer(int x, int y, glm::vec3* framebuffer, glm::vec2 resolution){
	if(x<resolution.x && y<resolution.y){
		int index = (y*resolution.x) + x;
		return framebuffer[index];
	}else{
		return glm::vec3(0,0,0);
	}
}

//Kernel that clears a given pixel buffer with a given color
__global__ void clearImage(glm::vec2 resolution, glm::vec3* image, glm::vec3 color){
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * resolution.x);
	if(x<=resolution.x && y<=resolution.y){
		image[index] = color;
	}
}

//Kernel that clears a given fragment buffer depth only. Everything else is ignored because it will be overwritten later
__global__ void clearDepthBuffer(glm::vec2 resolution, fragment* buffer){
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * resolution.x);
	if(x<=resolution.x && y<=resolution.y){
		buffer[index].depth= MAX_DEPTH;
	}
}

//Kernel that clears a given fragment buffer with a given fragment
__global__ void clearDepthBuffer(glm::vec2 resolution, fragment* buffer, fragment frag){
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * resolution.x);
	if(x<=resolution.x && y<=resolution.y){
		fragment f = frag;
		f.position.x = x;
		f.position.y = y;
		buffer[index] = f;
	}
}

//Kernel that writes the image to the OpenGL PBO directly. 
__global__ void sendImageToPBO(uchar4* PBOpos, glm::vec2 resolution, glm::vec3* image){

	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * resolution.x);

	if(x<=resolution.x && y<=resolution.y){

		glm::vec3 color;      
		color.x = image[index].x*255.0;
		color.y = image[index].y*255.0;
		color.z = image[index].z*255.0;

		if(color.x>255){
			color.x = 255;
		}

		if(color.y>255){
			color.y = 255;
		}

		if(color.z>255){
			color.z = 255;
		}

		// Each thread writes one pixel location in the texture (textel)
		PBOpos[index].w = 0;
		PBOpos[index].x = color.x;     
		PBOpos[index].y = color.y;
		PBOpos[index].z = color.z;
	}
}

__global__ void vertexShadeKernel(float* vbo, int vbosize,  float* nbo, int nbosize,  float* cbo, int cbosize,  vertex* verticies, uniforms* u_variables, pipelineOpts opts){
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if(index<vbosize/3){
		vertex vOut;

		glm::vec4 vertexEyePos = glm::vec4(vbo[index*3+0],vbo[index*3+1],vbo[index*3+2],1.0);
		vertexEyePos = u_variables->viewTransform*u_variables->modelTransform*vertexEyePos;

		//Compute lighting vectors
		glm::vec4 eyeLightPos = u_variables->viewTransform*u_variables->lightPos;
		glm::vec4 eyeLightDir = (eyeLightPos - vertexEyePos);
		glm::vec4 halfVector = (eyeLightDir - vertexEyePos);

		//Normals are in eye space
		glm::vec4 vertexEyeNorm = glm::vec4(nbo[index*3+0],nbo[index*3+1],nbo[index*3+2],0.0);
		vertexEyeNorm = u_variables->viewTransform*u_variables->modelTransform*vertexEyeNorm;

		glm::vec3 vertexColor = glm::vec3(cbo[(index%3)*3+0],cbo[(index%3)*3+1],cbo[(index%3)*3+2]);

		//Apply perspective matrix and perspective division
		glm::vec4 pos = u_variables->perspectiveTransform*vertexEyePos;
		pos.x /= pos.w;
		pos.y /= pos.w;
		pos.z /= pos.w;

		//Emit vertex
		vOut.pos       = glm::vec3(pos);
		vOut.eyeNormal = glm::normalize(glm::vec3(vertexEyeNorm));
		vOut.eyeHalfVector = glm::normalize(glm::vec3(halfVector));
		vOut.eyeLightDirection = glm::vec3(eyeLightDir);
		vOut.color = 	vertexColor;

		verticies[index] = vOut;
	}
}

//TODO: Implement primitive assembly
__global__ void primitiveAssemblyKernel(vertex* verticies, int* ibo, int ibosize, triangle* primitives, int* primitiveStageBuffer,
										uniforms* u_variables, pipelineOpts opts)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	int primitivesCount = ibosize/3;
	if(index<primitivesCount){
		//3 floats per vert, 3 verts per triangle
		triangle primitive;
		//Load verticies
		int vertIndex = ibo[index*3+0];
		primitive.v0 = verticies[vertIndex];
		vertIndex = ibo[index*3+1];
		primitive.v1 = verticies[vertIndex];
		vertIndex = ibo[index*3+2];
		primitive.v2 = verticies[vertIndex];


		//Write back primitive
		primitives[index] = primitive;
		primitiveStageBuffer[index] = index;//Throw triangle into buffer
	}
}


__global__ void backfaceCulling(triangle* primitives, int* primitiveStageBuffer, int NPrimitives, pipelineOpts opts)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if(index < NPrimitives)
	{
		int primIndex = primitiveStageBuffer[index];
		if(primIndex >= 0 && primIndex < NPrimitives){
			triangle tri = primitives[primIndex];
			float ux = tri.v1.pos.x-tri.v0.pos.x;
			float uy = tri.v1.pos.y-tri.v0.pos.y;
			float vx = tri.v2.pos.x-tri.v0.pos.x;
			float vy = tri.v2.pos.y-tri.v0.pos.y;

			float facing = ux*vy-uy*vx;

			if(facing < 0.0)
			{
				//Backface. Cull it.
				primitiveStageBuffer[index] = -1;
			}
		}
	}
}


__global__ void totalClipping(triangle* primitives, int* primitiveStageBuffer, int NPrimitives, pipelineOpts opts)
{

	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if(index < NPrimitives)
	{
		int primIndex = primitiveStageBuffer[index];
		if(primIndex >= 0 && primIndex < NPrimitives){
			triangle tri = primitives[primIndex];

			glm::vec3 minpoint, maxpoint;

			getAABBForTriangle(tri, minpoint,maxpoint);

			if(!isAABBInClipSpace(minpoint, maxpoint))
			{
				//Backface. Cull it.
				primitiveStageBuffer[index] = -1;
			}
		}
	}
}

//TODO: Do this a lot more efficiently and in parallel
__global__ void rasterizationKernel(triangle* primitives, int* primitiveStageBuffer, int primitivesCount, fragment* depthbuffer, 
									glm::vec2 resolution, uniforms* u_variables, pipelineOpts opts)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if(index<primitivesCount){
		int triIndex = primitiveStageBuffer[index];
		if(triIndex >= 0){


			//For each primitive
			//Load triangle localy
			triangle tri = primitives[triIndex];
			transformTriToScreenSpace(tri, resolution);

			//AABB for triangle
			glm::vec3 minPoint;
			glm::vec3 maxPoint;
			getAABBForTriangle(tri, minPoint, maxPoint);


			//Compute pixel range
			//Do some per-fragment clipping and restrict to screen space
			int minX = glm::max(glm::floor(minPoint.x),0.0f);
			int maxX = glm::min(glm::ceil(maxPoint.x),resolution.x);
			int minY = glm::max(glm::floor(minPoint.y),0.0f);
			int maxY = glm::min(glm::ceil(maxPoint.y),resolution.y);


			fragment frag;
			frag.primitiveIndex = index;
			//TODO: Do something more efficient than this
			for(int x = minX; x <= maxX; ++x)
			{
				for(int y = minY; y <= maxY; ++y)
				{
					int dbindex = getDepthBufferIndex(x,y,resolution);
					if(dbindex < 0)
						continue;

					frag.position.x = x;
					frag.position.y = y;

					glm::vec3 bCoords = calculateBarycentricCoordinate(tri, glm::vec2(x,y));
					if(isBarycentricCoordInBounds(bCoords))
					{
						//Blend values.
						frag.depth = tri.v0.pos.z*bCoords.x+tri.v1.pos.z*bCoords.y+tri.v2.pos.z*bCoords.z;
						if(frag.depth > 0.0f && frag.depth < 1.0f)
						{
							//Only continue if pixel is in screen.
							frag.color = tri.v0.color*bCoords.x+tri.v1.color*bCoords.y+tri.v2.color*bCoords.z;
							frag.normal = glm::normalize(tri.v0.eyeNormal*bCoords.x+tri.v1.eyeNormal*bCoords.y+tri.v2.eyeNormal*bCoords.z);
							frag.lightDir = glm::normalize(tri.v0.eyeLightDirection*bCoords.x+tri.v1.eyeLightDirection*bCoords.y+tri.v2.eyeLightDirection*bCoords.z);
							frag.halfVector = glm::normalize(tri.v0.eyeHalfVector*bCoords.x+tri.v1.eyeHalfVector*bCoords.y+tri.v2.eyeHalfVector*bCoords.z);


							fatomicMin(&(depthbuffer[dbindex].depthPrimTag),frag.depthPrimTag);

							if(frag.depthPrimTag == depthbuffer[dbindex].depthPrimTag)//If this is true, we won the race condition
								writeToDepthbuffer(x,y,frag, depthbuffer,resolution);

						}
					}
				}
			}
		}
	}
}


__global__ void binRasterizationKernel(triangle* primitives,  int* primitiveStageBuffer, int NPrimitives,
									   int* bufferCounters, int* binBuffers, int binBufferSize,
									   glm::vec2 resolution, glm::vec2 binDims, pipelineOpts opts)
{

	extern __shared__ int s[];
	int *sBufferCounters = s;
	
	int numBins = binDims.x*binDims.y;
	int *sBatchNum = &s[numBins]; 

	//threadIdx.x is id within batch
	int indexInBatch = threadIdx.x;
	int numBatchesPerBlock = blockDim.x;
	int binWidth = ceil(resolution.x/binDims.x);
	int binHeight = ceil(resolution.y/binDims.y);
	int indexInBlock = threadIdx.x+threadIdx.y*blockDim.x;
	//Initialize counters
	if(indexInBlock < numBins)
		sBufferCounters[indexInBlock] = 0;
	if(indexInBlock < blockDim.x)
		sBatchNum[indexInBlock] = 0;

	__syncthreads();


	while(sBatchNum[indexInBatch] < numBatchesPerBlock)
	{
		//Get a batch

		int batchId = atomicAdd(&sBatchNum[indexInBatch], 1);
		if(batchId < numBatchesPerBlock){
			int stageBufferIndex = indexInBatch + blockDim.x*(batchId*gridDim.x+blockIdx.x);
			if(stageBufferIndex < NPrimitives)
			{
				int triangleIndex = primitiveStageBuffer[stageBufferIndex];
				if(triangleIndex >= 0 && triangleIndex < NPrimitives){
					glm::vec3 minpoint,maxpoint;

					transformTriToScreenSpace(primitives[triangleIndex], resolution);
					getAABBForTriangle(primitives[triangleIndex], minpoint, maxpoint);

					for(int x = 0; x < binDims.x; ++x)
					{
						for(int y = 0; y < binDims.y; ++y)
						{
							if(isAABBInBin(minpoint, maxpoint, x*binWidth, (x+1)*binWidth, y*binHeight, (y+1)*binHeight))
							{
								int binIndex = x+y*binDims.x;
								int bufLoc = atomicAdd(&sBufferCounters[binIndex], 1);
								int binBufferIndex = bufLoc + binIndex*binBufferSize + blockIdx.x*(numBins*binBufferSize);
								binBuffers[binBufferIndex] = triangleIndex;
							}
						}
					}
				}
			}
		}
	}
	__syncthreads();

	if(indexInBlock < numBins)
		bufferCounters[indexInBlock] = sBufferCounters[indexInBlock];
}

__host__ __device__ void depthFSImpl(fragment* depthbuffer, int index,  uniforms* u_variables, pipelineOpts opts)
{
	float depth = depthbuffer[index].depth;
	if(depth < 1.0f)
		depthbuffer[index].color = glm::vec3(1.0f-depth); 
}


__host__ __device__ void ambientFSImpl(fragment* depthbuffer, int index,  uniforms* u_variables, pipelineOpts opts)
{
	//Do nothing. Interpolated color is assumed to be right
}


__host__ __device__ void blinnPhongFSImpl(fragment* depthbuffer, int index,  uniforms* u_variables, pipelineOpts opts)
{
	//TODO: Implement light color shading
	fragment frag = depthbuffer[index];
	glm::vec3 baseColor = frag.color;
	frag.color *= u_variables->blinnPhongParams.x;//Ambient term always present

	float NdotL = glm::max(glm::dot(frag.normal,frag.lightDir),0.0f);
	if (NdotL > 0.0f) {

		glm::vec3 diffuseColor = u_variables->diffuseColor;
		if(opts.showTriangleColors)
			diffuseColor = baseColor;

		frag.color += u_variables->blinnPhongParams.y * u_variables->lightColor * diffuseColor * NdotL;

		float NdotHV = glm::max(glm::dot(frag.normal,frag.halfVector),0.0f);

		glm::vec3 specularColor = u_variables->specularColor;
		if(opts.showTriangleColors)
			specularColor = baseColor;
		frag.color +=  u_variables->blinnPhongParams.z * u_variables->lightColor * specularColor * glm::pow(NdotHV, u_variables->shininess);
	}

	depthbuffer[index] = frag;
}

__host__ __device__ void normalFSImpl(fragment* depthbuffer, int index,  uniforms* u_variables, pipelineOpts opts)
{	
	glm::vec3 color = depthbuffer[index].normal;
	color.x = abs(color.x);
	color.y = abs(color.y);
	color.z = abs(color.z);
	depthbuffer[index].color = color; 

}


__global__ void fragmentShadeKernel(fragment* depthbuffer, glm::vec2 resolution, 
									uniforms* u_variables, pipelineOpts opts)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * resolution.x);
	if(x<=resolution.x && y<=resolution.y){
		if(depthbuffer[index].depth < MAX_DEPTH){
			switch(opts.fShaderProgram)
			{
			case DEPTH_SHADING:
				depthFSImpl(depthbuffer, index, u_variables, opts);
				break;
			case AMBIENT_LIGHTING:
				ambientFSImpl(depthbuffer, index, u_variables, opts);
				break;
			case NORMAL_SHADING:
				normalFSImpl(depthbuffer, index, u_variables, opts);
				break;
			case BLINN_PHONG_SHADING:
				blinnPhongFSImpl(depthbuffer, index, u_variables, opts);
				break;
			}
		}

	}
}

//Writes fragment colors to the framebuffer
__global__ void render(glm::vec2 resolution, fragment* depthbuffer, glm::vec3* framebuffer){

	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + (y * resolution.x);

	if(x<=resolution.x && y<=resolution.y){
		if(depthbuffer[index].depth < MAX_DEPTH){//Only 
			framebuffer[index] = depthbuffer[index].color;
		}
	}
}

// Wrapper for the __global__ call that sets up the kernel calls and does a ton of memory management
void cudaRasterizeCore(uchar4* PBOpos, glm::vec2 resolution, float frame, float* vbo, int vbosize, float* nbo, int nbosize, 
					   float* cbo, int cbosize, int* ibo, int ibosize, uniforms u_variables, pipelineOpts opts)
{

	// set up crucial magic
	int tileSize = 8;
	dim3 threadsPerBlock(tileSize, tileSize);
	dim3 fullBlocksPerGrid((int)ceil(float(resolution.x)/float(tileSize)), (int)ceil(float(resolution.y)/float(tileSize)));

	//set up framebuffer
	framebuffer = NULL;
	cudaMalloc((void**)&framebuffer, (int)resolution.x*(int)resolution.y*sizeof(glm::vec3));

	//set up depthbuffer
	depthbuffer = NULL;
	cudaMalloc((void**)&depthbuffer, (int)resolution.x*(int)resolution.y*sizeof(fragment));

	//kernel launches to black out accumulated/unaccumlated pixel buffers and clear our scattering states
	clearImage<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, framebuffer, glm::vec3(0,0,0));

	fragment frag;
	frag.color = glm::vec3(0.0f);
	frag.normal = glm::vec3(0.0f);
	frag.position = glm::vec2(0.0f,0.0f);
	frag.depth = MAX_DEPTH;
	clearDepthBuffer<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, depthbuffer);

	//------------------------------
	//memory stuff
	//------------------------------
	primitives = NULL;
	cudaMalloc((void**)&primitives, (ibosize/3)*sizeof(triangle));

	primitiveStageBuffer = NULL;
	cudaMalloc((void**)&primitiveStageBuffer, (ibosize/3)*sizeof(int));

	verticies = NULL;
	cudaMalloc((void**)&verticies, (vbosize)*sizeof(vertex));

	device_uniforms = NULL;
	cudaMalloc((void**)&device_uniforms, sizeof(uniforms));
	cudaMemcpy( device_uniforms, &u_variables, sizeof(uniforms), cudaMemcpyHostToDevice);


	device_ibo = NULL;
	cudaMalloc((void**)&device_ibo, ibosize*sizeof(int));
	cudaMemcpy( device_ibo, ibo, ibosize*sizeof(int), cudaMemcpyHostToDevice);

	device_vbo = NULL;
	cudaMalloc((void**)&device_vbo, vbosize*sizeof(float));
	cudaMemcpy( device_vbo, vbo, vbosize*sizeof(float), cudaMemcpyHostToDevice);

	device_nbo = NULL;
	cudaMalloc((void**)&device_nbo, nbosize*sizeof(float));
	cudaMemcpy( device_nbo, nbo, nbosize*sizeof(float), cudaMemcpyHostToDevice);

	device_cbo = NULL;
	cudaMalloc((void**)&device_cbo, cbosize*sizeof(float));
	cudaMemcpy( device_cbo, cbo, cbosize*sizeof(float), cudaMemcpyHostToDevice);

	tileSize = 32;
	int primitiveBlocks = ceil(((float)vbosize/3)/((float)tileSize));

	//------------------------------
	//vertex shader
	//------------------------------
	vertexShadeKernel<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, device_nbo, nbosize, device_cbo, cbosize, verticies, device_uniforms, opts);
	checkCUDAError("Kernel failed VS!");

	cudaDeviceSynchronize();
	//------------------------------
	//primitive assembly
	//------------------------------
	primitiveBlocks = ceil(((float)ibosize/3)/((float)tileSize));
	primitiveAssemblyKernel<<<primitiveBlocks, tileSize>>>(verticies,  device_ibo, ibosize, primitives, primitiveStageBuffer, device_uniforms, opts);


	cudaDeviceSynchronize();
	checkCUDAError("Kernel failed PA!");


	int NPrimitives = ibosize/3;
	if(opts.backfaceCulling)
	{
		backfaceCulling<<<primitiveBlocks, tileSize>>>(primitives, primitiveStageBuffer, NPrimitives, opts);
	}

	if(opts.totalClipping)
	{
		totalClipping<<<primitiveBlocks, tileSize>>>(primitives, primitiveStageBuffer, NPrimitives, opts);
	}

	//------------------------------
	//rasterization
	//------------------------------
	if(opts.rasterMode == NAIVE)
	{
		rasterizationKernel<<<primitiveBlocks, tileSize>>>(primitives, primitiveStageBuffer, NPrimitives, depthbuffer, resolution, device_uniforms, opts);
	}else if(opts.rasterMode == BIN){
		glm::vec2 binDims = glm::vec2(5,5);
		//Tuning params
		int binBufferSize = 2<<5;
		int batchSize = 32;//One batch per warp
		int numBlocks = 16;//max(2.0f, ceil(NPrimitives/float(batchSize*1024)));//At least the number of SMs, limited by size
		int batchesPerBlock = ceil(NPrimitives/float(batchSize*numBlocks));


		//Allocate bin buffers
		cudaMalloc((void**) &binBuffers, numBlocks*binDims.x*binDims.y*(binBufferSize)*sizeof(int));

		cudaMalloc((void**) &bufferCounters, numBlocks*binDims.x*binDims.y*sizeof(int));

		dim3 blockDims(batchSize, batchesPerBlock);
		dim3 gridDims(numBlocks);
		int Ns =  (binDims.x*binDims.y+batchSize)*sizeof(int);
		binRasterizationKernel<<<gridDims,blockDims,Ns>>>(
			primitives, primitiveStageBuffer, NPrimitives,
			bufferCounters, binBuffers, binBufferSize,
			resolution, binDims, opts);

		cudaFree(binBuffers);
		cudaFree(bufferCounters);
	}


	cudaDeviceSynchronize();
	checkCUDAError("Kernel failed Raster!");
	//------------------------------
	//fragment shader
	//------------------------------
	fragmentShadeKernel<<<fullBlocksPerGrid, threadsPerBlock>>>(depthbuffer, resolution, device_uniforms, opts);

	cudaDeviceSynchronize();
	checkCUDAError("Kernel failed FS!");
	//------------------------------
	//write fragments to framebuffer
	//------------------------------
	render<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, depthbuffer, framebuffer);
	sendImageToPBO<<<fullBlocksPerGrid, threadsPerBlock>>>(PBOpos, resolution, framebuffer);

	cudaDeviceSynchronize();

	kernelCleanup();

	checkCUDAError("Kernel failed!");
}

void kernelCleanup(){
	cudaFree( primitives );
	cudaFree( device_vbo );
	cudaFree( device_nbo);
	cudaFree( device_cbo );
	cudaFree( device_ibo );
	cudaFree( framebuffer );
	cudaFree( depthbuffer );
	cudaFree( verticies );
	cudaFree( device_uniforms);
}

