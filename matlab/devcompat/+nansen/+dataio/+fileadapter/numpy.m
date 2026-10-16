classdef numpy < nansen.dataio.FileAdapter
%numpy dev's nansen.dataio.fileadapter.numpy: a NumPy .npy file
%
%   A project's own adapters may subclass it, with dev's constants. Here
%   the file is read and written by the .npy adapter the shim gives
%   (CoreAdapter, from legacyFileAdapter.builtIn), which reads the array
%   itself, where dev converted the file to a .mat file with Python first.

    properties (Constant)
        DataType = 'struct'
    end

    properties (Constant, Hidden, Access = protected)
        SUPPORTED_FILE_TYPES = {'npy'}
    end

    methods (Access = protected)
        function data = readData(obj, varargin) %#ok<INUSD>
            data = obj.readWithCoreAdapter();
        end

        function writeData(obj, data, varargin) %#ok<INUSD>
            obj.writeWithCoreAdapter(data);
        end
    end
end
