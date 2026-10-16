classdef ImageStack < nansen.dataio.FileAdapter
%ImageStack dev's nansen.dataio.fileadapter.imagestack.ImageStack: a recording read as an image stack
%
%   dev's adapter of binary, TIFF, video, HDF5 and TSM recordings, which a
%   project's own adapters may subclass, with dev's constants. Here a file
%   is read and written by the adapter of its type that the shim gives
%   (CoreAdapter, from legacyFileAdapter.builtIn: the ophys module's
%   binary, TIFF, video, HDF5 or TSM stack), which reads the stack as an
%   array, height x width (x channels (x planes)) x frames, where dev gave
%   its virtual nansen.stack.ImageStack. A subclass's own readData and
%   writeData, and its other methods, run on top of it as they did in dev.

    properties (Constant)
        DataType = 'ImageStack'
        Description = 'This file contains image stack / video data';
    end

    properties (Constant, Hidden, Access = protected)
        SUPPORTED_FILE_TYPES = {'ini', 'raw', 'tif', 'tiff', 'avi', 'h5', 'tsm'}
    end

    methods (Access = protected)
        function imageStack = readData(obj, varargin) %#ok<INUSD>
            % (dev's dataset name of an HDF5 file: the adapter here reads its stack)
            imageStack = obj.readWithCoreAdapter();
        end

        function writeData(obj, data, varargin) %#ok<INUSD>
            obj.writeWithCoreAdapter(data);
        end
    end
end
