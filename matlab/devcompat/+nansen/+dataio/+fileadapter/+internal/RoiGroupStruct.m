classdef RoiGroupStruct < nansen.dataio.FileAdapter
%RoiGroupStruct dev's nansen.dataio.fileadapter.internal.RoiGroupStruct: a .mat file of ROI structs
%
%   A project's own adapters may subclass it, with dev's constants. Here
%   the file is read by the .mat adapter the shim gives (CoreAdapter, from
%   legacyFileAdapter.builtIn): its variables, as a struct, or the one
%   named.

    properties (Constant)
        DataType = 'struct'
    end

    properties (Constant, Hidden, Access = protected)
        SUPPORTED_FILE_TYPES = {'mat'}
    end

    methods (Access = protected)
        function data = readData(obj, varargin)
            data = obj.readWithCoreAdapter(varargin{:});
        end

        function writeData(obj, data, varargin)
            obj.writeWithCoreAdapter(data, varargin{:});
        end
    end
end
