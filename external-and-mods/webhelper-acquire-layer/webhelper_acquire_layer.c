// Implicit Vulkan layer: retries vkAcquireNextImage*KHR when it returns
// VK_TIMEOUT, for Steam's webhelper only.
//
// Chromium's GPU process waits up to 2 s for a swapchain image. CLOCK_MONOTONIC
// keeps running through device suspend and resume while user tasks are frozen,
// so a wait in flight at sleep has already expired at thaw and the driver returns
// VK_TIMEOUT at once. Chromium then treats the GPU process as hung and exits it.
// The image arrives soon after thaw, so asking again succeeds.
#define VK_NO_PROTOTYPES
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>

// A suspend gap costs one expired wait, the retry gets a fresh one. Three is
// enough to ride out a thaw and still ends a real stall.
#define MAX_RETRIES 3

typedef struct InstanceInfo {
  struct InstanceInfo *next;
  VkInstance instance;
  PFN_vkGetInstanceProcAddr gipa;
} InstanceInfo;

typedef struct DeviceInfo {
  struct DeviceInfo *next;
  VkDevice device;
  PFN_vkGetDeviceProcAddr gdpa;
  PFN_vkAcquireNextImageKHR acquire;
  PFN_vkAcquireNextImage2KHR acquire2;
  PFN_vkDestroyDevice destroy;
} DeviceInfo;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static InstanceInfo *g_instances;
static DeviceInfo *g_devices;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static int g_webhelper;

static void detect_webhelper(void) {
  char buf[64] = {0};
  FILE *f = fopen("/proc/self/comm", "r");
  if (!f)
    return;
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  buf[n] = 0;
  while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' '))
    buf[--n] = 0;
  g_webhelper = strcmp(buf, "steamwebhelper") == 0;
}

static int is_webhelper(void) {
  pthread_once(&g_once, detect_webhelper);
  return g_webhelper;
}

static InstanceInfo *newest_instance(void) {
  pthread_mutex_lock(&g_lock);
  InstanceInfo *i = g_instances;
  pthread_mutex_unlock(&g_lock);
  return i;
}

static PFN_vkGetInstanceProcAddr instance_gipa(VkInstance inst) {
  PFN_vkGetInstanceProcAddr r = NULL;
  pthread_mutex_lock(&g_lock);
  for (InstanceInfo *i = g_instances; i; i = i->next)
    if (i->instance == inst) {
      r = i->gipa;
      break;
    }
  pthread_mutex_unlock(&g_lock);
  return r;
}

static DeviceInfo *find_device(VkDevice dev, DeviceInfo *copy) {
  DeviceInfo *r = NULL;
  pthread_mutex_lock(&g_lock);
  for (DeviceInfo *d = g_devices; d; d = d->next)
    if (d->device == dev) {
      *copy = *d;
      r = copy;
      break;
    }
  pthread_mutex_unlock(&g_lock);
  return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_AcquireNextImageKHR(
    VkDevice device, VkSwapchainKHR swapchain, uint64_t timeout,
    VkSemaphore semaphore, VkFence fence, uint32_t *pImageIndex) {
  DeviceInfo d;
  if (!find_device(device, &d) || !d.acquire)
    return VK_ERROR_INITIALIZATION_FAILED;
  VkResult res = d.acquire(device, swapchain, timeout, semaphore, fence, pImageIndex);
  if (timeout == 0 || timeout == UINT64_MAX)
    return res;
  for (int n = 1; res == VK_TIMEOUT && n <= MAX_RETRIES; n++) {
    fprintf(stderr, "webhelper-acquire: VK_TIMEOUT, retry %d\n", n);
    res = d.acquire(device, swapchain, timeout, semaphore, fence, pImageIndex);
  }
  return res;
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_AcquireNextImage2KHR(
    VkDevice device, const VkAcquireNextImageInfoKHR *pAcquireInfo,
    uint32_t *pImageIndex) {
  DeviceInfo d;
  if (!find_device(device, &d) || !d.acquire2)
    return VK_ERROR_INITIALIZATION_FAILED;
  VkResult res = d.acquire2(device, pAcquireInfo, pImageIndex);
  uint64_t timeout = pAcquireInfo->timeout;
  if (timeout == 0 || timeout == UINT64_MAX)
    return res;
  for (int n = 1; res == VK_TIMEOUT && n <= MAX_RETRIES; n++) {
    fprintf(stderr, "webhelper-acquire: VK_TIMEOUT, retry %d\n", n);
    res = d.acquire2(device, pAcquireInfo, pImageIndex);
  }
  return res;
}

static VKAPI_ATTR void VKAPI_CALL layer_DestroyDevice(
    VkDevice device, const VkAllocationCallbacks *pAllocator) {
  PFN_vkDestroyDevice next = NULL;
  pthread_mutex_lock(&g_lock);
  for (DeviceInfo **p = &g_devices; *p; p = &(*p)->next)
    if ((*p)->device == device) {
      DeviceInfo *d = *p;
      *p = d->next;
      next = d->destroy;
      free(d);
      break;
    }
  pthread_mutex_unlock(&g_lock);
  if (next)
    next(device, pAllocator);
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL layer_GetDeviceProcAddr(
    VkDevice device, const char *pName);

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL layer_GetDeviceProcAddr(
    VkDevice device, const char *pName) {
  DeviceInfo d;
  if (!pName)
    return NULL;
  if (strcmp(pName, "vkGetDeviceProcAddr") == 0)
    return (PFN_vkVoidFunction)layer_GetDeviceProcAddr;
  if (strcmp(pName, "vkDestroyDevice") == 0)
    return (PFN_vkVoidFunction)layer_DestroyDevice;
  if (!find_device(device, &d) || !d.gdpa)
    return NULL;
  if (is_webhelper()) {
    if (strcmp(pName, "vkAcquireNextImageKHR") == 0 && d.acquire)
      return (PFN_vkVoidFunction)layer_AcquireNextImageKHR;
    if (strcmp(pName, "vkAcquireNextImage2KHR") == 0 && d.acquire2)
      return (PFN_vkVoidFunction)layer_AcquireNextImage2KHR;
  }
  return d.gdpa(device, pName);
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateInstance(
    const VkInstanceCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator, VkInstance *pInstance) {
  VkLayerInstanceCreateInfo *link = (VkLayerInstanceCreateInfo *)pCreateInfo->pNext;
  while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
                   link->function == VK_LAYER_LINK_INFO))
    link = (VkLayerInstanceCreateInfo *)link->pNext;
  if (!link || !link->u.pLayerInfo)
    return VK_ERROR_INITIALIZATION_FAILED;

  PFN_vkGetInstanceProcAddr next_gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
  PFN_vkCreateInstance next_create =
      (PFN_vkCreateInstance)next_gipa(VK_NULL_HANDLE, "vkCreateInstance");
  if (!next_create)
    return VK_ERROR_INITIALIZATION_FAILED;
  link->u.pLayerInfo = link->u.pLayerInfo->pNext;

  VkResult res = next_create(pCreateInfo, pAllocator, pInstance);
  if (res != VK_SUCCESS)
    return res;

  InstanceInfo *i = calloc(1, sizeof(*i));
  if (i) {
    i->instance = *pInstance;
    i->gipa = next_gipa;
    pthread_mutex_lock(&g_lock);
    i->next = g_instances;
    g_instances = i;
    pthread_mutex_unlock(&g_lock);
  }
  return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL layer_DestroyInstance(
    VkInstance instance, const VkAllocationCallbacks *pAllocator) {
  PFN_vkGetInstanceProcAddr gipa = instance_gipa(instance);
  PFN_vkDestroyInstance next =
      gipa ? (PFN_vkDestroyInstance)gipa(instance, "vkDestroyInstance") : NULL;
  pthread_mutex_lock(&g_lock);
  for (InstanceInfo **p = &g_instances; *p; p = &(*p)->next)
    if ((*p)->instance == instance) {
      InstanceInfo *i = *p;
      *p = i->next;
      free(i);
      break;
    }
  pthread_mutex_unlock(&g_lock);
  if (next)
    next(instance, pAllocator);
}

static VKAPI_ATTR VkResult VKAPI_CALL layer_CreateDevice(
    VkPhysicalDevice physicalDevice, const VkDeviceCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator, VkDevice *pDevice) {
  VkLayerDeviceCreateInfo *link = (VkLayerDeviceCreateInfo *)pCreateInfo->pNext;
  while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
                   link->function == VK_LAYER_LINK_INFO))
    link = (VkLayerDeviceCreateInfo *)link->pNext;
  if (!link || !link->u.pLayerInfo)
    return VK_ERROR_INITIALIZATION_FAILED;

  PFN_vkGetInstanceProcAddr next_gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
  PFN_vkGetDeviceProcAddr next_gdpa = link->u.pLayerInfo->pfnNextGetDeviceProcAddr;
  InstanceInfo *inst = newest_instance();
  PFN_vkCreateDevice next_create = (PFN_vkCreateDevice)next_gipa(
      inst ? inst->instance : VK_NULL_HANDLE, "vkCreateDevice");
  if (!next_create)
    return VK_ERROR_INITIALIZATION_FAILED;
  link->u.pLayerInfo = link->u.pLayerInfo->pNext;

  VkResult res = next_create(physicalDevice, pCreateInfo, pAllocator, pDevice);
  if (res != VK_SUCCESS)
    return res;

  DeviceInfo *d = calloc(1, sizeof(*d));
  if (d) {
    d->device = *pDevice;
    d->gdpa = next_gdpa;
    d->acquire = (PFN_vkAcquireNextImageKHR)next_gdpa(*pDevice, "vkAcquireNextImageKHR");
    d->acquire2 = (PFN_vkAcquireNextImage2KHR)next_gdpa(*pDevice, "vkAcquireNextImage2KHR");
    d->destroy = (PFN_vkDestroyDevice)next_gdpa(*pDevice, "vkDestroyDevice");
    pthread_mutex_lock(&g_lock);
    d->next = g_devices;
    g_devices = d;
    pthread_mutex_unlock(&g_lock);
  }
  return VK_SUCCESS;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL layer_GetInstanceProcAddr(
    VkInstance instance, const char *pName) {
  if (!pName)
    return NULL;
  if (strcmp(pName, "vkCreateInstance") == 0)
    return (PFN_vkVoidFunction)layer_CreateInstance;
  if (strcmp(pName, "vkDestroyInstance") == 0)
    return (PFN_vkVoidFunction)layer_DestroyInstance;
  if (strcmp(pName, "vkCreateDevice") == 0)
    return (PFN_vkVoidFunction)layer_CreateDevice;
  if (strcmp(pName, "vkGetInstanceProcAddr") == 0)
    return (PFN_vkVoidFunction)layer_GetInstanceProcAddr;
  if (strcmp(pName, "vkGetDeviceProcAddr") == 0)
    return (PFN_vkVoidFunction)layer_GetDeviceProcAddr;
  PFN_vkGetInstanceProcAddr gipa = instance ? instance_gipa(instance) : NULL;
  return gipa ? gipa(instance, pName) : NULL;
}

__attribute__((visibility("default")))
VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(
    VkNegotiateLayerInterface *pVersionStruct) {
  if (!pVersionStruct || pVersionStruct->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT ||
      pVersionStruct->loaderLayerInterfaceVersion < 2)
    return VK_ERROR_INITIALIZATION_FAILED;
  pVersionStruct->loaderLayerInterfaceVersion = 2;
  pVersionStruct->pfnGetInstanceProcAddr = layer_GetInstanceProcAddr;
  pVersionStruct->pfnGetDeviceProcAddr = layer_GetDeviceProcAddr;
  pVersionStruct->pfnGetPhysicalDeviceProcAddr = NULL;
  return VK_SUCCESS;
}
