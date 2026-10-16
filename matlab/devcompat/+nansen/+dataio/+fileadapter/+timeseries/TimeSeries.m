classdef TimeSeries < nansen.dataio.FileAdapter
%TimeSeries dev's nansen.dataio.fileadapter.timeseries.TimeSeries: time series, a variable each of a .mat file
%
%   A project's own adapters may subclass it, with dev's constants. Here
%   the file is read by the .mat adapter the shim gives (CoreAdapter, from
%   legacyFileAdapter.builtIn): its variables, as a struct, or the one
%   named, as the arrays they are where dev made them timeseries objects.
%   save(obj, data, name) writes that variable and keeps the file's others,
%   as dev did.

    properties (Constant)
        DataType = 'timeseries'
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
