#include "utils.h"

static int cunn_TemporalConvolution_updateOutput(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");
  int kW = luaT_getfieldcheckint(L, 1, "kW");
  int dW = luaT_getfieldcheckint(L, 1, "dW");
  int inputFrameSize = luaT_getfieldcheckint(L, 1, "inputFrameSize");
  int outputFrameSize = luaT_getfieldcheckint(L, 1, "outputFrameSize");

  THCudaTensor *weight = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "weight", "torch.CudaTensor");
  THCudaTensor *bias = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "bias", "torch.CudaTensor");
  THCudaTensor *output = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "output", "torch.CudaTensor");

  THCudaTensor *outputWindow, *inputWindow;
  int nInputFrame, nOutputFrame;
  long k, i;

  int dimS = 0; // sequence dimension
  int dimF = 1; // feature dimension

  luaL_argcheck(L, input->nDimension == 2 || input->nDimension == 3, 2, "2D or 3D(batch mode) tensor expected");

  if (input->nDimension == 3)
  {
    dimS = 1;
    dimF = 2;
  }
  luaL_argcheck(L, input->size[dimF] == inputFrameSize, 2, "invalid input frame size");
  luaL_argcheck(L, input->size[dimS] >= kW, 2, "input sequence smaller than kernel size");

  input = THCudaTensor_newContiguous(input);
  outputWindow = THCudaTensor_new();
  inputWindow = THCudaTensor_new();

  nInputFrame = input->size[dimS];
  nOutputFrame = (nInputFrame - kW) / dW + 1;

  if (input->nDimension == 2)
  {
    THCudaTensor_resize2d(output,
                          nOutputFrame,
                          outputFrameSize);

    /* bias first */
    for(k = 0; k < nOutputFrame; k++)
    {
      THCudaTensor_select(outputWindow, output, 0, k);
      THCudaTensor_copy(outputWindow, bias);
    }


    /* ouch */
    for(k = 0; nOutputFrame > 0; k++)
    {
      long outputFrameStride = (kW-1)/dW+1;
      long inputFrameStride = outputFrameStride*dW;
      long nFrame = (nInputFrame-k*dW-kW)/inputFrameStride + 1;
      nOutputFrame -= nFrame;

      THCudaTensor_setStorage2d(inputWindow, input->storage,
                              input->storageOffset+k*dW*input->size[1],
                              nFrame, inputFrameStride*input->size[1],
                              kW*input->size[1], 1);

      THCudaTensor_setStorage2d(outputWindow, output->storage,
                              output->storageOffset + k*output->size[1],
                              nFrame, outputFrameStride*output->size[1],
                              output->size[1], 1);

      THCudaTensor_transpose(weight, NULL, 0, 1);
      THCudaTensor_addmm(getCutorchState(L)->blasState, outputWindow, 1, outputWindow, 1, inputWindow, weight);
      THCudaTensor_transpose(weight, NULL, 0, 1);
    }
  }
  else
  {
    THCudaTensor *outputSample = THCudaTensor_new();
    THCudaTensor *inputSample = THCudaTensor_new();
    int nBatchFrame = input->size[0];

    THCudaTensor_resize3d(output,
                          nBatchFrame,
                          nOutputFrame,
                          outputFrameSize);

    for(i = 0; i < nBatchFrame; i++)
    {
      THCudaTensor_select(outputSample, output, 0, i);
      THCudaTensor_select(inputSample, input, 0, i);
      long nOutputSampleFrame = nOutputFrame;

      /* bias first */
      for(k = 0; k < nOutputFrame; k++)
      {
        THCudaTensor_select(outputWindow, outputSample, 0, k);
        THCudaTensor_copy(outputWindow, bias);
      }

      /* ouch */
      for(k = 0; nOutputSampleFrame > 0; k++)
      {
        long outputFrameStride = (kW-1)/dW+1;
        long inputFrameStride = outputFrameStride*dW;
        long nFrame = (nInputFrame-k*dW-kW)/inputFrameStride + 1;
        nOutputSampleFrame -= nFrame;

        THCudaTensor_setStorage2d(inputWindow, inputSample->storage,
                                inputSample->storageOffset+k*dW*inputSample->size[1],
                                nFrame, inputFrameStride*inputSample->size[1],
                                kW*inputSample->size[1], 1);

        THCudaTensor_setStorage2d(outputWindow, outputSample->storage,
                                outputSample->storageOffset + k*outputSample->size[1],
                                nFrame, outputFrameStride*outputSample->size[1],
                                outputSample->size[1], 1);

        THCudaTensor_transpose(weight, NULL, 0, 1);
        THCudaTensor_addmm(getCutorchState(L)->blasState, outputWindow, 1, outputWindow, 1, inputWindow, weight);
        THCudaTensor_transpose(weight, NULL, 0, 1);
      }
    }
    THCudaTensor_free(outputSample);
    THCudaTensor_free(inputSample);
  }

  THCudaTensor_free(outputWindow);
  THCudaTensor_free(inputWindow);
  THCudaTensor_free(input);

  return 1;
}

static int cunn_TemporalConvolution_updateGradInput(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *gradOutput = (THCudaTensor*)luaT_checkudata(L, 3, "torch.CudaTensor");
  int kW = luaT_getfieldcheckint(L, 1, "kW");
  int dW = luaT_getfieldcheckint(L, 1, "dW");
  long nInputFrame;
  long nOutputFrame;

  THCudaTensor *weight = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "weight", "torch.CudaTensor");
  THCudaTensor *gradInput = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "gradInput", "torch.CudaTensor");

  THCudaTensor *gradOutputWindow;
  THCudaTensor *gradInputWindow;
  long k, i;

  int dimS = 0; // sequence dimension

  if (gradOutput->nDimension == 3)
  {
    dimS = 1;
  }

  nInputFrame = input->size[dimS];
  nOutputFrame = gradOutput->size[dimS];


  /* Not necessary with partial backprop: */
  gradOutputWindow = THCudaTensor_new();
  gradInputWindow = THCudaTensor_new();

  THCudaTensor_resizeAs(gradInput, input);
  THCudaTensor_zero(gradInput);

  if (gradOutput->nDimension == 2)
  {
    /* ouch */
    for(k = 0; nOutputFrame > 0; k++)
    {
      long outputFrameStride = (kW-1)/dW+1;
      long inputFrameStride = outputFrameStride*dW;
      long nFrame = (nInputFrame-k*dW-kW)/inputFrameStride + 1;
      nOutputFrame -= nFrame;

      THCudaTensor_setStorage2d(gradOutputWindow, gradOutput->storage,
                              gradOutput->storageOffset + k*gradOutput->size[1],
                              nFrame, outputFrameStride*gradOutput->size[1],
                              gradOutput->size[1], 1);

      THCudaTensor_setStorage2d(gradInputWindow, gradInput->storage,
                              gradInput->storageOffset+k*dW*gradInput->size[1],
                              nFrame, inputFrameStride*gradInput->size[1],
                              kW*gradInput->size[1], 1);

      THCudaTensor_addmm(getCutorchState(L)->blasState, gradInputWindow, 1, gradInputWindow, 1, gradOutputWindow, weight);
    }
  }
  else
  {
    THCudaTensor *gradOutputSample = THCudaTensor_new();
    THCudaTensor *gradInputSample = THCudaTensor_new();
    long nBatchFrame = input->size[0];
    for(i = 0; i < nBatchFrame; i++)
    {
      THCudaTensor_select(gradOutputSample, gradOutput, 0, i);
      THCudaTensor_select(gradInputSample, gradInput, 0, i);
      long nOutputSampleFrame = nOutputFrame;

      /* ouch */
      for(k = 0; nOutputSampleFrame > 0; k++)
      {
        long outputFrameStride = (kW-1)/dW+1;
        long inputFrameStride = outputFrameStride*dW;
        long nFrame = (nInputFrame-k*dW-kW)/inputFrameStride + 1;
        nOutputSampleFrame -= nFrame;

        THCudaTensor_setStorage2d(gradOutputWindow, gradOutputSample->storage,
                                gradOutputSample->storageOffset + k*gradOutputSample->size[1],
                                nFrame, outputFrameStride*gradOutputSample->size[1],
                                gradOutputSample->size[1], 1);

        THCudaTensor_setStorage2d(gradInputWindow, gradInputSample->storage,
                                gradInputSample->storageOffset+k*dW*gradInputSample->size[1],
                                nFrame, inputFrameStride*gradInputSample->size[1],
                                kW*gradInputSample->size[1], 1);

        THCudaTensor_addmm(getCutorchState(L)->blasState, gradInputWindow, 1, gradInputWindow, 1, gradOutputWindow, weight);
      }
    }
    THCudaTensor_free(gradOutputSample);
    THCudaTensor_free(gradInputSample);
  }

  THCudaTensor_free(gradOutputWindow);
  THCudaTensor_free(gradInputWindow);

  return 1;
}

static int cunn_TemporalConvolution_accGradParameters(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *gradOutput = (THCudaTensor*)luaT_checkudata(L, 3, "torch.CudaTensor");
  float scale = luaL_optnumber(L, 4, 1);
  int kW = luaT_getfieldcheckint(L, 1, "kW");
  int dW = luaT_getfieldcheckint(L, 1, "dW");
  long nInputFrame;
  long nOutputFrame;

  THCudaTensor *gradWeight = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "gradWeight", "torch.CudaTensor");
  THCudaTensor *gradBias = (THCudaTensor*)luaT_getfieldcheckudata(L, 1, "gradBias", "torch.CudaTensor");

  THCudaTensor *gradOutputWindow;
  THCudaTensor *inputWindow;
  long k, i;

  int dimS = 0; // sequence dimension

  if (gradOutput->nDimension == 3)
  {
    dimS = 1;
  }

  nInputFrame = input->size[dimS];
  nOutputFrame = gradOutput->size[dimS];

  /* Not necessary with partial backprop: */
  input = THCudaTensor_newContiguous(input);
  gradOutputWindow = THCudaTensor_new();
  inputWindow = THCudaTensor_new();

  if (input->nDimension == 2)
  {
    /* bias first */
    for(k = 0; k < nOutputFrame; k++)
    {
      THCudaTensor_select(gradOutputWindow, gradOutput, 0, k);
      THCudaTensor_cadd(getCutorchState(L)->blasState, gradBias, gradBias, scale, gradOutputWindow);
    }

    /* ouch */
    for(k = 0; nOutputFrame > 0; k++)
    {
      long outputFrameStride = (kW-1)/dW+1;
      long inputFrameStride = outputFrameStride*dW;
      long nFrame = (nInputFrame-k*dW-kW)/inputFrameStride + 1;
      nOutputFrame -= nFrame;

      THCudaTensor_setStorage2d(inputWindow, input->storage,
                              input->storageOffset+k*dW*input->size[1],
                              nFrame, inputFrameStride*input->size[1],
                              kW*input->size[1], 1);

      THCudaTensor_setStorage2d(gradOutputWindow, gradOutput->storage,
                              gradOutput->storageOffset + k*gradOutput->size[1],
                              nFrame, outputFrameStride*gradOutput->size[1],
                              gradOutput->size[1], 1);

      THCudaTensor_transpose(gradOutputWindow, NULL, 0, 1);
      THCudaTensor_addmm(getCutorchState(L)->blasState, gradWeight, 1, gradWeight, scale, gradOutputWindow, inputWindow);
      THCudaTensor_transpose(gradOutputWindow, NULL, 0, 1);
    }
  }
  else
  {
    THCudaTensor *gradOutputSample = THCudaTensor_new();
    THCudaTensor *inputSample = THCudaTensor_new();
    long nBatchFrame = input->size[0];

    for(i = 0; i < nBatchFrame; i++)
    {
      THCudaTensor_select(gradOutputSample, gradOutput, 0, i);
      THCudaTensor_select(inputSample, input, 0, i);
      long nOutputSampleFrame = nOutputFrame;

      /* bias first */
      for(k = 0; k < nOutputFrame; k++)
      {
        THCudaTensor_select(gradOutputWindow, gradOutputSample, 0, k);
        THCudaTensor_cadd(getCutorchState(L)->blasState, gradBias, gradBias, scale, gradOutputWindow);
      }

      /* ouch */
      for(k = 0; nOutputSampleFrame > 0; k++)
      {
        long outputFrameStride = (kW-1)/dW+1;
        long inputFrameStride = outputFrameStride*dW;
        long nFrame = (nInputFrame-k*dW-kW)/inputFrameStride + 1;
        nOutputSampleFrame -= nFrame;

        THCudaTensor_setStorage2d(inputWindow, inputSample->storage,
                                inputSample->storageOffset+k*dW*inputSample->size[1],
                                nFrame, inputFrameStride*inputSample->size[1],
                                kW*inputSample->size[1], 1);

        THCudaTensor_setStorage2d(gradOutputWindow, gradOutputSample->storage,
                                gradOutputSample->storageOffset + k*gradOutputSample->size[1],
                                nFrame, outputFrameStride*gradOutputSample->size[1],
                                gradOutputSample->size[1], 1);

        THCudaTensor_transpose(gradOutputWindow, NULL, 0, 1);
        THCudaTensor_addmm(getCutorchState(L)->blasState, gradWeight, 1, gradWeight, scale, gradOutputWindow, inputWindow);
        THCudaTensor_transpose(gradOutputWindow, NULL, 0, 1);
      }
    }
    THCudaTensor_free(gradOutputSample);
    THCudaTensor_free(inputSample);
  }

  THCudaTensor_free(gradOutputWindow);
  THCudaTensor_free(inputWindow);
  THCudaTensor_free(input);

  return 1;
}

static const struct luaL_Reg cunn_TemporalConvolution__ [] = {
  {"TemporalConvolution_updateOutput", cunn_TemporalConvolution_updateOutput},
  {"TemporalConvolution_updateGradInput", cunn_TemporalConvolution_updateGradInput},
  {"TemporalConvolution_accGradParameters", cunn_TemporalConvolution_accGradParameters},
  {NULL, NULL}
};

static void cunn_TemporalConvolution_init(lua_State *L)
{
  luaT_pushmetatable(L, "torch.CudaTensor");
  luaT_registeratname(L, cunn_TemporalConvolution__, "nn");
  lua_pop(L,1);
}
