classdef (Sealed) BinTrace < handle & nansen.dataio.FileAdapter
%BinTrace A trace of doubles in a binary file.

    properties (Constant)
        DataType = "double" % in double quotes
        Description = 'Doubles, little-endian, one after the other'
    end

    properties (Constant, Hidden, Access = protected)
        SUPPORTED_FILE_TYPES = 'bin'
    end

    methods (Access = protected)
        function data = readData(obj, varargin)
            fid = fopen(obj.Filename, 'r', 'l');
            data = fread(fid, Inf, 'double')';
            fclose(fid);
        end
    end
end
