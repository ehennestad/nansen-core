function masks = roiMasks(document, height, width)
%roiMasks Logical height x width masks of the ROIs of an ROI file, in a cell array
    if isfield(document, "imageSize")
        size_ = reshape(double(document.imageSize), 1, []);
        if ~isequal(size_, [height, width])
            nansen.internal.throwError("invalid-data", "the ROIs are for %d x %d images, the stack is %d x %d", ...
                size_(1), size_(2), height, width)
        end
    end
    rois = {};
    if isfield(document, "rois") && ~isempty(document.rois)
        rois = document.rois;
        if isstruct(rois)
            rois = num2cell(rois);
        end
    end
    masks = cell(1, numel(rois));
    for i = 1:numel(rois)
        pixels = rois{i}.pixels;
        if iscell(pixels)
            pixels = cell2mat(cellfun(@(p) reshape(double(p), 1, 2), pixels(:), UniformOutput=false));
        end
        pixels = reshape(double(pixels), [], 2);
        mask = false(height, width);
        mask(sub2ind([height, width], pixels(:, 1) + 1, pixels(:, 2) + 1)) = true;
        masks{i} = mask;
    end
end
