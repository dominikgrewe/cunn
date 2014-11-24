#ifndef CUNN_UTILS_H
#define CUNN_UTILS_H

#include <lua.h>
#include "THCGeneral.h"

THCudaState* getCutorchState(lua_State* L);

#endif
