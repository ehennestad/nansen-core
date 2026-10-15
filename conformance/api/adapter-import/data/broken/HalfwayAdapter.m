classdef HalfwayAdapter
%HalfwayAdapter Reads, but has no write: not a file adapter yet
    methods
        function data = read(~, path)
            data = fileread(path);
        end
    end
end
