function rois = roiList(document)
%roiList The ROIs of an ROI file as a cell array of structs, however jsondecode gave them
    rois = {};
    if isstruct(document) && isfield(document, "rois") && ~isempty(document.rois)
        rois = document.rois;
        if isstruct(rois)
            rois = num2cell(rois);
        end
        rois = reshape(rois, 1, []);
    end
    for i = 1:numel(rois)
        pixels = nansen.internal.getField(rois{i}, "pixels", zeros(0, 2));
        if iscell(pixels)
            pixels = cell2mat(cellfun(@(p) reshape(double(p), 1, 2), pixels(:), UniformOutput=false));
        end
        rois{i}.pixels = reshape(double(pixels), [], 2);
    end
end
