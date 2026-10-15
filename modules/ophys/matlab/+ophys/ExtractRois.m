classdef ExtractRois < nansen.FileAdapter
%ExtractRois EXTRACT's output saved in a .mat file: output.spatial_weights (height x width x cells)
%
%   Each cell's ROI is the 8-connected area around its peak of pixels
%   weighing at least 0.2 of the peak, as ophys.extract keeps them. Read
%   only. Python's ophys_adapters.ExtractRois reads the same.

    methods
        function data = read(~, path)
            contents = load(path);
            if ~isfield(contents, "output") || ~isfield(contents.output, "spatial_weights")
                nansen.internal.throwError("invalid-data", "%s has no output.spatial_weights of EXTRACT", path)
            end
            weights = double(full(contents.output.spatial_weights));
            lists = cell(1, size(weights, 3));
            for k = 1:size(weights, 3)
                lists{k} = ophys.internal.weightsPixels(weights(:, :, k));
            end
            data = ophys.internal.roiDocument(size(weights, 1:2), lists);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "EXTRACT's files are written by EXTRACT; ROIs are saved as JSON")
        end
    end
end
