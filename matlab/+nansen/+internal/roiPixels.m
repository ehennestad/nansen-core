function pixels = roiPixels(roi)
%roiPixels An ROI's [row, column] pixels as an N-by-2 matrix, however jsondecode gave them
    pixels = nansen.internal.getField(roi, "pixels", zeros(0, 2));
    if iscell(pixels)
        pixels = cell2mat(cellfun(@(p) reshape(double(p), 1, 2), pixels(:), UniformOutput=false));
    end
    pixels = reshape(double(pixels), [], 2);
end
