classdef Net
%Net Stub of DeepInterpolation-MATLAB's deepinterp.Net: a "network" of 40 x 36 frames that predicts a frame as
%the mean of the frames interp gives it, at deepinterp.Net's own offsets (Npre before, Npost after, Nomit left out)

    properties (SetAccess = protected)
        N = 40
        M = 36
        Npre
        Npost
        Nomit
    end

    methods
        function obj = Net(command, varargin)
            options = struct(varargin{:});
            assert(any(strcmpi(command, {'KerasFile', 'matlab'})), "unknown command %s", command)
            assert(ischar(options.file) && isfile(options.file), "no file %s", options.file)
            obj.Npre = options.Npre;
            obj.Npost = options.Npost;
            obj.Nomit = options.Nomit;
        end

        function output = interp(obj, input, varargin)
            assert(isequal(size(input, 1:2), [obj.N, obj.M]), "frames of %s, not %d x %d", mat2str(size(input)), obj.N, obj.M)
            assert(isa(input, "single"), "not single")
            output = input;
            omitPre = (obj.Nomit + 1) / 2;
            omitPost = (obj.Nomit + 1) / 2;
            offsets = [fliplr(-(omitPre:obj.Npre + omitPre - 1)), omitPost:obj.Npost + omitPost - 1];
            for t = obj.Npre + omitPre:size(input, 3) - obj.Npost - omitPost + 1
                output(:, :, t) = mean(input(:, :, offsets + t), 3);
            end
        end
    end
end
