function rois = shapeRois(image, inner, outer)
%shapeRois Somata found by their shape in an image, as flufinder's shapeDetection: a cell array of [row, column] pixels (1-based)
%
%   The image, scaled to 0..1, is correlated with a ring template
%   (ophys.internal.ringKernel); where the correlation is above sqrt(0.2)
%   of its largest, areas (8-connected) of 5 pixels or more are candidates,
%   at their centroid rounded half up, 15 px from the edge or more.
%   Candidates whose 21 x 21 patch correlates with the candidates' mean
%   patch by 0.1 or less are left out; each one's mask is found by
%   ophys.internal.somaMask and kept when the ring is brighter than both its
%   edges in more than 60 % of directions and it overlaps no soma kept
%   before it by more than 75 %. As Python's ophys_methods.shape_rois.
    margin = 15;
    rois = {};
    im = double(image);
    im = im - min(im, [], "all");
    top = max(im, [], "all");
    if ~(top > 0)
        return
    end
    im = im / top;
    score = ophys.internal.templateCorrelation(im, ophys.internal.ringKernel(im, inner, outer));
    finite = score(isfinite(score));
    if isempty(finite) || ~(max(finite) > 0)
        return
    end
    scaled = score / max(finite);
    scaled(isnan(scaled)) = 0;
    selected = scaled > sqrt(0.2);
    [height, width] = size(im);
    areas = ophys.internal.components(selected, 8);
    centres = zeros(0, 2);   % 0-based
    for i = 1:numel(areas)
        area = areas{i};
        if size(area, 1) < 5
            continue
        end
        cy = floor(sum(area(:, 1) - 1) / size(area, 1) + 0.5);
        cx = floor(sum(area(:, 2) - 1) / size(area, 1) + 0.5);
        if cy >= margin && cy <= height - 1 - margin && cx >= margin && cx <= width - 1 - margin
            centres(end + 1, :) = [cy, cx]; %#ok<AGROW>
        end
    end
    if isempty(centres)
        return
    end
    patches = cell(1, size(centres, 1));
    meanPatch = zeros(21, 21);
    for i = 1:size(centres, 1)
        patches{i} = im(centres(i, 1) - 9:centres(i, 1) + 11, centres(i, 2) - 9:centres(i, 2) + 11);
        meanPatch = meanPatch + patches{i};
    end
    meanPatch = meanPatch / numel(patches);
    for i = 1:size(centres, 1)
        if ~(pearson(meanPatch, patches{i}) > 0.1)
            continue
        end
        [pixels, ridge] = ophys.internal.somaMask(im, centres(i, 1), centres(i, 2));
        if ridge > 0.6 && ~isempty(pixels) && ~any(cellfun(@(r) ophys.internal.overlapShare(pixels, r) > 0.75, rois))
            rois{end + 1} = pixels; %#ok<AGROW>
        end
    end
end

function value = pearson(a, b)
    a = a - mean(a, "all");
    b = b - mean(b, "all");
    scale = sqrt(sum(a .* a, "all") * sum(b .* b, "all"));
    if scale > 0
        value = sum(a .* b, "all") / scale;
    else
        value = NaN;
    end
end
