classdef RoiArray < nansen.dataio.FileAdapter
%RoiArray dev's nansen.dataio.fileadapter.roi.RoiArray: a .mat file of ROIs
%
%   A project's own adapters may subclass it, with dev's constants. Here a
%   file is read and written by the adapter the shim gives (CoreAdapter,
%   from legacyFileAdapter.builtIn: the ophys module's nansen_roi_array),
%   as nansen.dataio.fileadapter.roi.RoiGroup.

    properties (Constant)
        DataType = 'RoI'
    end

    properties (Constant, Hidden, Access = protected)
        SUPPORTED_FILE_TYPES = {'mat'}
    end

    methods (Access = protected)
        function roiArray = readData(obj, varargin) %#ok<INUSD>
            roiArray = obj.readWithCoreAdapter();
        end

        function writeData(obj, data, varargin) %#ok<INUSD>
            obj.writeWithCoreAdapter(data);
        end
    end
end
