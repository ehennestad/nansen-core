classdef CaimanRois < nansen.FileAdapter
%CaimanRois CaImAn's HDF5 results: estimates/A (sparse spatial components, pixels in Fortran order) and dims
%
%   Each component's ROI is the 8-connected area around its peak of pixels
%   weighing at least 0.2 of the peak (ophys.internal.weightsPixels). Read
%   only. Python's ophys_adapters.CaimanRois reads the same.

    methods
        function data = read(~, path)
            try
                values = h5read(path, "/estimates/A/data");
                indices = double(h5read(path, "/estimates/A/indices"));
                pointers = double(h5read(path, "/estimates/A/indptr"));
                dims = double(h5read(path, "/dims"));
            catch
                nansen.internal.throwError("invalid-data", "%s has no estimates/A and dims of CaImAn's results", path)
            end
            dims = reshape(dims(1:2), 1, 2);
            lists = cell(1, numel(pointers) - 1);
            for k = 1:numel(pointers) - 1
                image = zeros(dims);
                range = pointers(k) + 1:pointers(k + 1);
                image(indices(range) + 1) = values(range);   % Fortran order is MATLAB's own
                lists{k} = ophys.internal.weightsPixels(image);
            end
            data = ophys.internal.roiDocument(dims, lists);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "CaImAn's files are written by CaImAn; ROIs are saved as JSON")
        end
    end
end
