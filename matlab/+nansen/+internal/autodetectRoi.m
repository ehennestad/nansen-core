function pixels = autodetectRoi(stack, point, radius, mode, image)
%autodetectRoi An ROI found around a point of a stack in one of dev's roimanager autodetection modes
%
%   pixels = autodetectRoi(stack, point, radius, mode) gives the 0-based
%   [row, column] pixels (row-major order) of the ROI found around point
%   (0-based [row, column]) of a height x width x frames nansen.Stack, as
%   dev's roiMap.autodetectRoi2 and autodetectRoi find it in modes 1-5 (the
%   autoDetect pointer tool's keys 1-5); radius is the tool's circle (dev's
%   default 6). Mode 0 is not dev's: the threshold of
%   nansen.internal.detectRoi, which looks within radius of the point.
%   image (optional) is what modes 0 and 3-5 work on: the stack's mean.
%
%   1, dev's default: a box of 2 (r + 5) + 1 pixels around the point (0
%      outside the image); the ROI's signal, the mean of the box's pixels
%      within r of the point, over every frame; its dF/F (dffClassic)
%      normalised to 0..1 and weighted 1 / (1 + exp(-10 (x - 0.5))); the box
%      less its mean, weighted and averaged over the frames (computeRoiImages'
%      Activity Weighted Mean), as 8 bits; then flufinder's
%      findSomaMaskByEdgeDetection, centred on the point.
%   2, the box of r + 5 cut at the image's edges; the maximum over the
%      frames where the signal is above its 5th percentile, 2 frames either
%      side (findActiveSamplePoints); findSomaMaskByThresholding (outer
%      diameter 2 r).
%   3, the image's box of r + 5 as 8 bits (makeuint8), then
%      findSomaMaskByThresholding. 4, as 3 in a box of r + 11 (dev's
%      extendedRadius). 5, the image's box of r + 5, then
%      findSomaMaskByEdgeDetection.
%
%   Every step is written out here in the same order as Python's
%   nansen.autodetect, with no toolbox function (imresize, imgaussfilt,
%   poly2mask, medfilt2, bwareaopen, imfill and prctile are written here),
%   so both find the same pixels.
    if nargin < 5
        image = [];
    end
    if ~(isnumeric(mode) && isscalar(mode) && any(mode == 0:5))
        nansen.internal.throwError("invalid-params", "mode is 0, 1, 2, 3, 4 or 5, not %s", jsonencode(mode))
    end
    [height, width, frames] = size(stack);
    row = double(point(1));
    column = double(point(2));
    if row < 0 || row >= height || column < 0 || column >= width
        nansen.internal.throwError("invalid-params", "the point %s is not in the %d x %d image", jsonencode(point), height, width)
    end
    if mode == 0
        if isempty(image)
            image = nansen.internal.meanImage(stack);
        end
        pixels = nansen.internal.detectRoi(image, point, radius);
        return
    end
    pad = 5;         % dev's pad around the circle (autodetectRoi2)
    extended = 11;   % dev's extendedRadius (6 + 5), the extra padding of mode 4
    chunk = 100;     % frames read at a time
    r = max(1, fix(double(radius)));
    x = column + 1;  % dev's 1-based pixel coordinates
    y = row + 1;
    out = false(height, width);
    if mode == 1
        boxSize = 2 * (r + pad) + 1;
        top = y - (r + pad);   % getImageSubsetBounds, boundaryMethod none: not cut at the edges
        left = x - (r + pad);
        [signal, total] = boxSignal(stack, top, left, boxSize, boxSize, r + pad + 1, r + pad + 1, r);
        weights = sigmoidWeights(signal);
        offset = total / (boxSize * boxSize * frames);   % the box's mean over every frame (SubtractBaseline)
        weighted = zeros(boxSize, boxSize);
        for start = 1:chunk:frames
            part = box(stack.frames(start, start + chunk - 1), top, left, boxSize, boxSize);
            for t = 1:size(part, 3)
                weighted = weighted + (part(:, :, t) - offset) * weights(start + t - 1);
            end
        end
        roiImage = castUint8(normalise(weighted / frames) * 255);
        mask = somaMaskByEdges(roiImage, true);
        half = (boxSize + 1) / 2;   % placeLocalRoiMaskInFovMask: ceil(size / 2)
        for i = 1:boxSize
            for j = 1:boxSize
                yy = i - half + y;
                xx = j - half + x;
                if mask(i, j) && yy >= 1 && yy <= height && xx >= 1 && xx <= width
                    out(yy, xx) = true;
                end
            end
        end
    else
        if mode == 4
            pad = extended;
        end
        top = max(y - (r + pad), 1);   % getImageSubsetBounds, cut at the edges
        bottom = min(y + (r + pad), height);
        left = max(x - (r + pad), 1);
        right = min(x + (r + pad), width);
        rows = bottom - top + 1;
        columns = right - left + 1;
        if mode == 2
            signal = boxSignal(stack, top, left, rows, columns, y - top + 1, x - left + 1, r);
            active = activeSamples(signal);
            peak = [];
            for start = 1:chunk:frames
                part = box(stack.frames(start, start + chunk - 1), top, left, rows, columns);
                for t = 1:size(part, 3)
                    if active(start + t - 1)
                        if isempty(peak)
                            peak = part(:, :, t);
                        else
                            peak = max(peak, part(:, :, t));
                        end
                    end
                end
            end
            mask = somaMaskByThreshold(peak, 2 * r);
        else
            if isempty(image)
                image = nansen.internal.meanImage(stack);
            end
            part = double(image(top:bottom, left:right));
            if mode == 5
                mask = somaMaskByEdges(part, false);
            else
                mask = somaMaskByThreshold(makeUint8(part), 2 * r);
            end
        end
        out(top:bottom, left:right) = mask;
    end
    [rr, cc] = find(out);
    pixels = sortrows([rr(:), cc(:)]) - 1;
end

% --- the ROI's signal and its weights ----------------------------------------------------------------------------------

function out = box(part, top, left, rows, columns)
    % getPixelChunk: rows x columns pixels from (top, left) of a height x width x frames chunk, 0 outside
    [h, w, n] = size(part);
    out = zeros(rows, columns, n);
    r0 = max(top, 1);
    r1 = min(top + rows - 1, h);
    c0 = max(left, 1);
    c1 = min(left + columns - 1, w);
    if r0 <= r1 && c0 <= c1
        out(r0 - top + 1:r1 - top + 1, c0 - left + 1:c1 - left + 1, :) = double(part(r0:r1, c0:c1, :));
    end
end

function [signal, total] = boxSignal(stack, top, left, rows, columns, cy, cx, r)
    % The mean over the box's pixels within r of (cy, cx) (dy^2 + dx^2 < r^2, getCircularMask), added in
    % column-major order, in each frame (extractSingleRoi); and the sum of the box over every frame
    [ii, jj] = ndgrid(1:rows, 1:columns);
    inside = find((ii - cy) .^ 2 + (jj - cx) .^ 2 < r * r);
    weight = 0;
    if ~isempty(inside)
        weight = 1 / numel(inside);
    end
    frames = size(stack, 3);
    signal = zeros(frames, 1);
    total = 0;
    for start = 1:100:frames
        part = box(stack.frames(start, start + 99), top, left, rows, columns);
        n = size(part, 3);
        flat = reshape(part, rows * columns, n);
        values = zeros(1, n);
        sums = zeros(1, n);
        for k = 1:numel(inside)
            values = values + weight * flat(inside(k), :);
        end
        for k = 1:rows * columns   % each frame's sum, column after column
            sums = sums + flat(k, :);
        end
        signal(start:start + n - 1) = values;
        for t = 1:n
            total = total + sums(t);
        end
    end
end

function weights = sigmoidWeights(signal)
    % computeRoiImages' weights: dF/F (dffClassic: (f - f0) / f0, f0 the 20th percentile), normalised, as a sigmoid
    f0 = prctileOf(signal, 20);
    dff = (signal - f0) / f0;
    weights = 1 ./ (1 + exp(-10 * (normalise(dff) - 0.5)));
end

function out = normalise(values)
    % (x - min) / (max - min); 0 when the values are flat or not all finite
    out = zeros(size(values));
    if isempty(values) || ~all(isfinite(values(:)))
        return
    end
    low = min(values(:));
    high = max(values(:));
    if ~(high > low)
        return
    end
    out = (values - low) / (high - low);
end

function out = castUint8(values)
    % MATLAB's uint8 (rounded half away from zero, cut at 0 and 255, NaN as 0), kept as doubles
    out = min(max(floor(values + 0.5), 0), 255);
    out(isnan(out)) = 0;
end

function v = prctileOf(values, p)
    % MATLAB's prctile of a vector (NaN left out): the sorted values at 100 (i - 0.5) / n, linear between them
    x = sort(values(:));
    x = x(~isnan(x));
    n = numel(x);
    if n == 0
        v = NaN;
        return
    end
    r = (p / 100) * n;
    k = floor(r + 0.5);
    kp1 = min(k + 1, n);
    r = r - k;
    k = max(k, 1);
    if r == -0.5 || x(k) == x(kp1)
        v = x(k);
    else
        v = (0.5 + r) * x(kp1) + (0.5 - r) * x(k);
    end
end

function active = activeSamples(signal)
    % findActiveSamplePoints: the frames above p50 - (p50 - p5), and 2 on either side of each; else the first peak
    p5 = prctileOf(signal, 5);
    p50 = prctileOf(signal, 50);
    above = find(signal > p50 - (p50 - p5));
    n = numel(signal);
    active = false(n, 1);
    for k = 1:numel(above)
        active(max(1, above(k) - 2):min(n, above(k) + 2)) = true;
    end
    if ~any(active)
        [~, at] = max(signal);
        active(at) = true;
    end
end

function out = makeUint8(image)
    % stack.makeuint8 in single precision: from the sorted values at round(n 0.0005) and round(n 0.9995) to 0..255
    data = single(image);
    ordered = sort(data(:));
    ordered = ordered(~isnan(ordered));
    n = numel(ordered);
    if n == 0
        out = zeros(size(data));
        return
    end
    low = ordered(max(round(n * 0.0005), 1));
    high = ordered(min(round(n * (1 - 0.0005)), n));
    out = castUint8(double(((data - low) ./ (high - low)) .* single(255)));
end

% --- flufinder's findSomaMaskByThresholding ------------------------------------------------------------------------------

function mask = somaMaskByThreshold(image, outerDiameter)
    % findSomaMaskByThresholding with InnerDiameter 0: halfway from the median outside the circle to the median
    % inside it (0s left out), on the image median filtered over 5 x 5 (0 outside, NaN last); less areas smaller
    % than round(pi r^2 / 2) (8-connected), holes filled (4-connected)
    im = double(image);
    im(im == 0) = NaN;
    [h, w] = size(im);
    r2 = outerDiameter / 2;
    minArea = round(pi * (r2 ^ 2) / 2);
    [yy, xx] = ndgrid((1:h) - h / 2, (1:w) - w / 2);
    soma = (xx .^ 2 + yy .^ 2) < r2 ^ 2;
    high = medianSorted(sortNumbers(im(soma)));
    low = medianSorted(sortNumbers(im(~soma)));
    threshold = low + (high - low) / 2;
    padded = zeros(h + 4, w + 4);
    padded(3:h + 2, 3:w + 2) = im;
    filtered = zeros(h, w);
    for i = 1:h
        for j = 1:w
            values = sort(reshape(padded(i:i + 4, j:j + 4), [], 1));   % NaN last
            filtered(i, j) = values(13);
        end
    end
    mask = filtered > threshold;
    mask = fillHoles(areaOpen(mask, minArea));
end

function x = sortNumbers(values)
    x = sort(values(:));
    x = x(~isnan(x));
end

function m = medianSorted(x)
    % MATLAB's median of sorted values: the middle, or a + (b - a) / 2 ((a + b) / 2 when their signs differ)
    n = numel(x);
    if n == 0
        m = NaN;
    elseif mod(n, 2) == 1
        m = x((n + 1) / 2);
    else
        a = x(n / 2);
        b = x(n / 2 + 1);
        if sign(a) ~= sign(b) || isinf(a) || isinf(b)
            m = (a + b) / 2;
        else
            m = a + (b - a) / 2;
        end
    end
end

function [labels, count] = components(mask, eight)
    % The connected areas of a mask, numbered
    [h, w] = size(mask);
    if eight
        steps = [-1, -1; -1, 0; -1, 1; 0, -1; 0, 1; 1, -1; 1, 0; 1, 1];
    else
        steps = [-1, 0; 1, 0; 0, -1; 0, 1];
    end
    labels = zeros(h, w);
    count = 0;
    for j = 1:w
        for i = 1:h
            if ~mask(i, j) || labels(i, j) > 0
                continue
            end
            count = count + 1;
            labels(i, j) = count;
            todo = [i, j];
            while ~isempty(todo)
                here = todo(end, :);
                todo(end, :) = [];
                for s = 1:size(steps, 1)
                    n = here + steps(s, :);
                    if n(1) >= 1 && n(1) <= h && n(2) >= 1 && n(2) <= w && mask(n(1), n(2)) && labels(n(1), n(2)) == 0
                        labels(n(1), n(2)) = count;
                        todo(end + 1, :) = n; %#ok<AGROW>
                    end
                end
            end
        end
    end
end

function out = areaOpen(mask, minSize)
    % bwareaopen: the mask less its 8-connected areas of fewer than minSize pixels
    out = mask;
    [labels, count] = components(mask, true);
    for k = 1:count
        if nnz(labels == k) < minSize
            out(labels == k) = false;
        end
    end
end

function out = fillHoles(mask)
    % imfill holes: the 4-connected areas of the rest that do not reach the edge, filled
    out = mask;
    [h, w] = size(mask);
    [labels, count] = components(~mask, false);
    for k = 1:count
        area = labels == k;
        if ~any(area(1, :)) && ~any(area(h, :)) && ~any(area(:, 1)) && ~any(area(:, w))
            out(area) = true;
        end
    end
end

% --- flufinder's findSomaMaskByEdgeDetection -----------------------------------------------------------------------------

function mask = somaMaskByEdges(image, rounded)
    % findSomaMaskByEdgeDetection (rounded: 8-bit values, rounded again after every step): 4 times larger
    % (bicubic), unrolled into rings, blurred (sigma 1) and differentiated along the radius; the nucleus's edge
    % (the largest rise, mended, smoothed over 9 directions) when significant, then the soma's (the largest fall
    % from it out to 1.2 times its mean radius); the pixels inside that edge, scaled back, 2/4 pixel further out
    upsampling = 4;
    im = double(image);
    [h, w] = size(im);
    mask = false(h, w);
    big = imresizeAlong(imresizeAlong(im, 1, upsampling * h, rounded), 2, upsampling * w, rounded);
    unrolled = imunroll(big, rounded);
    [rings, angles] = size(unrolled);
    if rings < 3
        return
    end
    unrolled = gaussBlur(unrolled, rounded);
    grad = unrolled(2:end, :) - unrolled(1:end - 1, :);
    [inner, innerValues] = findEdge(grad, true);
    innerSmooth = circularSmooth(inner, 2 * upsampling + 1);
    if meanOf(innerValues) / stdOf(innerValues) > 1.5   % isSignificantBoundary (EdgeValue2)
        search = cropGradient(grad, innerSmooth);
    else
        search = grad;
        innerSmooth = ones(1, angles);
    end
    outer = findEdge(search, false);
    outerSmooth = circularSmooth(outer, 2 * upsampling + 1);
    limit = size(grad, 1);
    xs = zeros(1, angles);
    ys = zeros(1, angles);
    for k = 1:angles
        edge = min(max(outerSmooth(k) + innerSmooth(k), 1), limit);
        radius = edge / upsampling + 2 / upsampling;
        theta = (pi / 180) * ((k - 1) * (360 / angles));
        xs(k) = w / 2 + radius * cos(theta) + 0.5;
        ys(k) = h / 2 - radius * sin(theta) + 0.5;
    end
    for i = 1:h
        for j = 1:w
            mask(i, j) = insidePolygon(xs, ys, j, i);
        end
    end
end

function f = cubic(x)
    % imresize's bicubic kernel (a = -0.5)
    a = abs(x);
    a2 = a * a;
    a3 = a2 * a;
    f = (1.5 * a3 - 2.5 * a2 + 1) * (a <= 1) + (-0.5 * a3 + 2.5 * a2 - 4 * a + 2) * ((1 < a) && (a <= 2));
end

function out = imresizeAlong(data, dim, len, rounded)
    % imresize along a dimension to len samples, bicubic, antialiased when it shrinks (MATLAB's contributions:
    % weights normalised to sum 1, edges mirrored, all-zero columns dropped); rounded: then as uint8
    if dim == 2
        data = data.';
    end
    n = size(data, 1);
    scale = len / n;
    kernelWidth = 4;
    shrink = scale < 1;
    if shrink
        kernelWidth = kernelWidth / scale;
    end
    count = ceil(kernelWidth) + 2;
    weights = zeros(len, count);
    indices = zeros(len, count);
    for x = 1:len
        u = x / scale + 0.5 * (1 - 1 / scale);
        left = floor(u - kernelWidth / 2);
        for p = 1:count
            if shrink
                weights(x, p) = scale * cubic(scale * (u - (left + p - 1)));
            else
                weights(x, p) = cubic(u - (left + p - 1));
            end
        end
        total = 0;
        for p = 1:count
            total = total + weights(x, p);
        end
        weights(x, :) = weights(x, :) / total;
        indices(x, :) = left + (0:count - 1);
    end
    mirror = [1:n, n:-1:1];
    kept = find(any(weights ~= 0, 1));
    out = zeros(len, size(data, 2));
    for x = 1:len
        value = zeros(1, size(data, 2));
        for p = kept
            value = value + weights(x, p) * data(mirror(mod(indices(x, p) - 1, numel(mirror)) + 1), :);
        end
        out(x, :) = value;
    end
    if rounded
        out = min(max(floor(out + 0.5), 0), 255);
    end
    if dim == 2
        out = out.';
    end
end

function out = imunroll(image, rounded)
    % imunroll: row r holds the pixels at rounded distance r from the centre in order of their angle (0..360,
    % counterclockwise from the right; ties in column-major order), resized to the image's width
    [h, w] = size(image);
    cy = (h + 1) / 2;
    cx = (w + 1) / 2;
    rings = round(min(w - cx, h - cy));
    [ii, jj] = ndgrid(1:h, 1:w);
    xx = jj - cx;
    yy = -(ii - cy);
    distance = round(hypot(xx, yy));
    angle = atan2(yy, xx) * (180 / pi);
    negative = angle < 0;
    angle(negative) = 180 + (180 - abs(angle(negative)));
    out = zeros(max(rings, 0), w);
    for r = 1:rings
        index = find(distance == r);
        [~, order] = sort(angle(index));
        values = image(index(order));
        out(r, :) = imresizeAlong(values(:), 1, w, rounded).';
    end
end

function out = gaussBlur(image, rounded)
    % imgaussfilt, sigma 1: a 5-sample Gaussian along the columns, then the rows, edges repeated
    kernel = zeros(1, 5);
    for k = 1:5
        kernel(k) = exp(-((k - 3) * (k - 3)) / 2);
    end
    total = 0;
    for k = 1:5
        total = total + kernel(k);
    end
    kernel = kernel / total;
    out = double(image);
    [h, w] = size(out);
    padded = [out([1, 1], :); out; out([h, h], :)];
    value = zeros(h, w);
    for k = 1:5
        value = value + kernel(k) * padded(k:k + h - 1, :);
    end
    out = value;
    padded = [out(:, [1, 1]), out, out(:, [w, w])];
    value = zeros(h, w);
    for k = 1:5
        value = value + kernel(k) * padded(:, k:k + w - 1);
    end
    out = value;
    if rounded
        out = min(max(floor(out + 0.5), 0), 255);
    end
end

function [best, at] = peakOf(values, rise)
    % The largest (rise) or smallest value that is not NaN and the index of the first; (NaN, 1) when none
    best = NaN;
    at = 1;
    for k = 1:numel(values)
        v = values(k);
        if isnan(v)
            continue
        end
        if isnan(best) || (rise && v > best) || (~rise && v < best)
            best = v;
            at = k;
        end
    end
end

function [coords, values] = findEdge(grad, rise)
    % flufinder's findEdge: each column's largest rise (or fall), and its jumps of 5 or more mended
    [rows, columns] = size(grad);
    coords = zeros(1, columns);
    values = zeros(1, columns);
    for c = 1:columns
        [values(c), coords(c)] = peakOf(grad(:, c), rise);
    end
    middle = medianSorted(sort(coords));
    spread = stdOf(coords);
    count = 0;
    while true
        jumps = coords - coords([columns, 1:columns - 1]);
        if all(jumps < 5)
            break
        end
        at = 1;
        for k = 2:columns
            if jumps(k) > jumps(at)
                at = k;
            end
        end
        if coords(at) > middle + spread
            bound = round(max(1, coords(at) - 2));
            [values(at), k] = peakOf(grad(1:bound, at), rise);
            coords(at) = k;
        elseif coords(at) < middle - spread
            bound = round(min(coords(at) + 2, rows));
            [values(at), k] = peakOf(grad(bound:end, at), rise);
            coords(at) = k + bound - 1;
        else
            if at == 1
                before = columns;
            else
                before = at - 1;
            end
            halfway = (coords(before) + coords(at)) / 2;
            if values(before) > values(at)
                coords(before) = halfway;
                values(before) = grad(round(halfway), before);
            else
                coords(at) = halfway;
                values(at) = grad(round(halfway), at);
            end
        end
        count = count + 1;
        if count > columns
            break
        end
        middle = medianSorted(sort(coords));
        spread = stdOf(coords);
    end
end

function out = cropGradient(grad, boundary)
    % updateGradientImage: each column from row round(boundary) on, moved to the top (NaN below; a longer column
    % adds rows of 0s, as MATLAB grows an array), cut at ceil(1.2 mean(boundary)) rows
    [rows, columns] = size(grad);
    lower = floor(min(boundary));
    out = NaN(rows - lower, columns);
    for j = 1:columns
        values = grad(round(boundary(j)):end, j);
        if numel(values) > size(out, 1)
            out = [out; zeros(numel(values) - size(out, 1), columns)]; %#ok<AGROW>
        end
        out(1:numel(values), j) = values;
    end
    upper = ceil(meanOf(boundary) * 1.2);
    out = out(1:min(size(out, 1), upper), :);
end

function out = circularSmooth(values, window)
    % circularsmooth: the mean of the window values around each, wrapping around, added in order
    n = numel(values);
    half = floor(window / 2);
    out = zeros(1, n);
    for i = 1:n
        total = 0;
        for k = -half:half
            total = total + values(mod(i - 1 + k, n) + 1);
        end
        out(i) = total / window;
    end
end

function m = meanOf(values)
    total = 0;
    for k = 1:numel(values)
        total = total + values(k);
    end
    m = total / numel(values);
end

function s = stdOf(values)
    % The standard deviation (n - 1), added in order
    n = numel(values);
    if n < 2
        s = 0;
        return
    end
    m = meanOf(values);
    total = 0;
    for k = 1:n
        total = total + (values(k) - m) * (values(k) - m);
    end
    s = sqrt(total / (n - 1));
end

function inside = insidePolygon(xs, ys, px, py)
    % Even-odd rule: is (px, py) inside the polygon of the points (xs, ys)?
    inside = false;
    j = numel(xs);
    for i = 1:numel(xs)
        if (ys(i) > py) ~= (ys(j) > py) && px < (xs(j) - xs(i)) * (py - ys(i)) / (ys(j) - ys(i)) + xs(i)
            inside = ~inside;
        end
        j = i;
    end
end
