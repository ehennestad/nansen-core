classdef RoiGroup < nansen.dataio.FileAdapter
%RoiGroup dev's nansen.dataio.fileadapter.roi.RoiGroup: a file of ROIs
%
%   dev's adapter of ROI files (its own, and suite2p's), which a project's
%   own adapters may subclass, with dev's constants. Here a file is read
%   and written by the adapter of its type that the shim gives
%   (CoreAdapter, from legacyFileAdapter.builtIn: the ophys module's
%   nansen_roi_array for dev's .mat files, which keeps their
%   classifications, and suite2p_rois for .npy), which reads the ROIs as
%   the ophys module's ROI document where dev gave its roimanager.roiGroup.
%   A subclass's own readData and writeData, and its other methods, run on
%   top of it as they did in dev.

    properties (Constant)
        DataType = 'RoiGroup'
        Description = 'This file contains information about a group of rois';
    end

    properties (Constant, Hidden, Access = protected)
        SUPPORTED_FILE_TYPES = {'mat', 'npy'}
    end

    methods (Access = protected)
        function roiGroup = readData(obj, varargin) %#ok<INUSD>
            roiGroup = obj.readWithCoreAdapter();
        end

        function writeData(obj, data, varargin) %#ok<INUSD>
            obj.writeWithCoreAdapter(data);
        end
    end
end
