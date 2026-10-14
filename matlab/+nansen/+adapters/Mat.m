classdef Mat < nansen.FileAdapter
%Mat A MATLAB .mat file as a struct of variables
%
%   Writing a struct saves its fields as variables; any other value is
%   saved as a variable named data (as the Python adapter does).
    methods
        function data = read(~, path)
            data = load(path);
        end

        function write(~, path, data)
            if ~(isstruct(data) && isscalar(data))
                data = struct("data", {data});
            end
            save(path, "-struct", "data");
        end
    end
end
