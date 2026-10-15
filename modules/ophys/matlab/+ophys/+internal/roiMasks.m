function masks = roiMasks(document, height, width)
%roiMasks Logical height x width masks of the ROIs of an ROI file, in a cell array
    if isfield(document, "imageSize")
        size_ = reshape(double(document.imageSize), 1, []);
        if ~isequal(size_, [height, width])
            nansen.internal.throwError("invalid-data", "the ROIs are for %d x %d images, the stack is %d x %d", ...
                size_(1), size_(2), height, width)
        end
    end
    rois = ophys.internal.roiList(document);
    masks = cell(1, numel(rois));
    for i = 1:numel(rois)
        pixels = rois{i}.pixels;
        mask = false(height, width);
        mask(sub2ind([height, width], pixels(:, 1) + 1, pixels(:, 2) + 1)) = true;
        masks{i} = mask;
    end
end
