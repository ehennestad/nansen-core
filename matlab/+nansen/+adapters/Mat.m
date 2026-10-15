classdef Mat < nansen.FileAdapter
%Mat A MATLAB .mat file as a struct of variables
%
%   Writing a struct saves its fields as variables; any other value is
%   saved as a variable named data (as the Python adapter does). Data of
%   2 GB or more is saved in the v7.3 format (HDF5), which the default
%   format cannot hold; Python reads both.
    methods
        function data = read(~, path)
            data = load(path);
        end

        function write(~, path, data)
            if ~(isstruct(data) && isscalar(data))
                data = struct("data", {data});
            end
            info = whos("data");
            if info.bytes >= 2^31
                save(path, "-struct", "data", "-v7.3");
            else
                save(path, "-struct", "data");
            end
        end
    end
end
