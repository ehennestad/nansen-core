classdef SpeedTrace < nansen.dataio.FileAdapter
%SPEEDTRACE Running speed, one sample per line.

    properties (Constant)
        DataType = 'double'
    end

    properties (Constant, Hidden, Access = protected)
        SUPPORTED_FILE_TYPES = {'speed', '.spd'} % as dev wrote them, with or without the dot
    end

    methods (Access = protected)
        function data = readData(obj, varargin)
            data = reshape(sscanf(fileread(obj.Filename), '%f'), 1, []);
        end

        function writeData(obj, data, varargin)
            fid = fopen(obj.Filename, 'w');
            fprintf(fid, '%g\n', data);
            fclose(fid);
        end
    end
end
