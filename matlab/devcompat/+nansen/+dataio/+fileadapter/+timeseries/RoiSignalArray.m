classdef RoiSignalArray < nansen.dataio.FileAdapter
%RoiSignalArray dev's nansen.dataio.fileadapter.timeseries.RoiSignalArray: ROI signals, a variable each of a .mat file
%
%   A project's own adapters may subclass it, with dev's constants. Here
%   the file is read by the .mat adapter the shim gives (CoreAdapter, from
%   legacyFileAdapter.builtIn): its variables, as a struct, or the one
%   named (load(obj, 'dff')), as the arrays they are where dev made them a
%   timetable. save(obj, data, name) writes that variable and keeps the
%   file's others, as dev did; dev's metadata of the file is not kept.

    properties (Constant)
        DataType = 'RoiSignalArray'
        Description = 'This file contains extracted and processed roi signals';
    end

    properties
        OutputFormat = 'array'   % dev's timetable or timeseries: here the signals are read as the arrays in the file
    end

    properties (Constant, Hidden, Access = protected)
        SUPPORTED_FILE_TYPES = {'mat'}
    end

    methods (Access = protected)
        function roiSignalArray = readData(obj, varargin)
            roiSignalArray = obj.readWithCoreAdapter(varargin{:});
        end

        function writeData(obj, data, varargin)
            obj.writeWithCoreAdapter(data, varargin{:});
        end
    end
end
