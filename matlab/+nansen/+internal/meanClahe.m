function image = meanClahe(stack)
%meanClahe dev's Mean CLAHE projection (stack.zproject.meanclahe) of a height x width x frames stack
%
%   The mean over the frames, normalised to 0..1 (from its smallest to its
%   largest finite value), contrast-limited adaptive histogram equalisation
%   (dev's adapthisteq with 32 x 32 tiles, clip limit 0.015 and a Rayleigh
%   distribution, written out below, no toolbox), scaled back to the mean's
%   range and, for a stack of whole numbers, rounded as its type (half away
%   from zero, cut at the type's range). An image smaller than 32 pixels
%   either way is the normalised mean, as dev's; a flat one, the mean.
%   Python's nansen.frames.mean_clahe gives the same values.
    if ~isa(stack, "nansen.Stack")
        stack = nansen.Stack.fromArray(stack, 3);
    end
    average = nansen.internal.meanImage(stack);
    finite = average(isfinite(average));
    if isempty(finite) || ~(max(finite) > min(finite))
        image = average;
        return
    end
    low = min(finite);
    high = max(finite);
    normal = (average - low) / (high - low);
    if size(average, 1) < 32 || size(average, 2) < 32
        image = normal;
        return
    end
    image = clahe(normal) * (high - low) + low;
    className = char(stack.ClassName);
    if any(strcmp(className, ["uint8", "uint16", "uint32", "uint64", "int8", "int16", "int32", "int64"]))
        image = min(max(sign(image) .* floor(abs(image) + 0.5), double(intmin(className))), double(intmax(className)));
    end
end

function out = clahe(image)
    % adapthisteq with NumTiles [32 32], ClipLimit 0.015, NBins 256, Distribution rayleigh (Alpha 0.4), Range original
    % (0..1 here): mirror-padded to whole tiles of even sizes, each tile's clipped histogram mapped, and each pixel
    % the bilinear mix of the four tiles' mappings around it, as makeClaheImage adds them
    tiles = 32;
    bins = 256;
    alpha = 0.4;
    [height, width] = size(image);
    sizes = [height, width];
    before = zeros(1, 2);
    after = zeros(1, 2);
    for d = 1:2
        if mod(sizes(d), tiles) ~= 0
            tile = floor(sizes(d) / tiles) + 1;
        else
            tile = sizes(d) / tiles;
        end
        pad = tile * tiles - sizes(d);
        if mod(tile, 2) == 1
            pad = pad + tiles;
        end
        before(d) = floor(pad / 2);
        after(d) = pad - floor(pad / 2);
    end
    rowIndex = [before(1):-1:1, 1:height, height:-1:height - after(1) + 1];   % mirrored, the edge pixel repeated
    columnIndex = [before(2):-1:1, 1:width, width:-1:width - after(2) + 1];
    padded = image(rowIndex, columnIndex);
    rows = size(padded, 1) / tiles;
    columns = size(padded, 2) / tiles;
    count = rows * columns;
    least = ceil(count / bins);
    limit = least + round(0.015 * (count - least));
    binned = min(max(floor(padded * (bins - 1) + 0.5), 0), bins - 1);
    binned(isnan(binned)) = 0;
    hconst = 2 * alpha ^ 2;
    vmax = 1 - exp(-1 / hconst);
    maps = cell(tiles, tiles);
    for c = 1:tiles
        for r = 1:tiles
            tile = binned((r - 1) * rows + 1:r * rows, (c - 1) * columns + 1:c * columns);
            histogram = accumarray(tile(:) + 1, 1, [bins, 1]).';
            histogram = clipHistogram(histogram, limit, bins);
            cumulative = cumsum(histogram);
            value = vmax * (cumulative / count);
            value(value >= 1) = 1 - eps;
            maps{r, c} = min(0 + sqrt(-hconst * log(1 - value)) * 1, 1);
        end
    end
    out = zeros(size(padded));
    top = 1;
    for k = 1:tiles + 1
        if k == 1
            heightK = rows / 2;
            mapRows = [1, 1];
        elseif k == tiles + 1
            heightK = rows / 2;
            mapRows = [tiles, tiles];
        else
            heightK = rows;
            mapRows = [k - 1, k];
        end
        left = 1;
        for m = 1:tiles + 1
            if m == 1
                widthM = columns / 2;
                mapColumns = [1, 1];
            elseif m == tiles + 1
                widthM = columns / 2;
                mapColumns = [tiles, tiles];
            else
                widthM = columns;
                mapColumns = [m - 1, m];
            end
            index = binned(top:top + heightK - 1, left:left + widthM - 1) + 1;
            rowW = repmat((0:heightK - 1)', 1, widthM);
            rowRev = repmat((heightK:-1:1)', 1, widthM);
            columnW = repmat(0:widthM - 1, heightK, 1);
            columnRev = repmat(widthM:-1:1, heightK, 1);
            ul = maps{mapRows(1), mapColumns(1)};
            ur = maps{mapRows(1), mapColumns(2)};
            bl = maps{mapRows(2), mapColumns(1)};
            br = maps{mapRows(2), mapColumns(2)};
            out(top:top + heightK - 1, left:left + widthM - 1) = ...
                (rowRev .* (columnRev .* ul(index) + columnW .* ur(index)) + ...
                 rowW .* (columnRev .* bl(index) + columnW .* br(index))) / (heightK * widthM);
            left = left + widthM;
        end
        top = top + heightK;
    end
    out = out(before(1) + 1:before(1) + height, before(2) + 1:before(2) + width);
end

function histogram = clipHistogram(histogram, limit, bins)
    % adapthisteq's clipHistogram: counts above limit cut to it, the excess handed back evenly, then one at a time
    excess = sum(max(histogram - limit, 0));
    share = floor(excess / bins);
    upper = limit - share;
    for k = 1:bins
        if histogram(k) > limit
            histogram(k) = limit;
        elseif histogram(k) > upper
            excess = excess - (limit - histogram(k));
            histogram(k) = limit;
        else
            excess = excess - share;
            histogram(k) = histogram(k) + share;
        end
    end
    start = 1;
    while excess ~= 0
        step = max(floor(bins / excess), 1);
        for m = start:step:bins
            if histogram(m) < limit
                histogram(m) = histogram(m) + 1;
                excess = excess - 1;
                if excess == 0
                    break
                end
            end
        end
        start = start + 1;
        if start > bins
            start = 1;
        end
    end
end
