function result = alignSessions(entities, options, context)
%alignSessions Align each entity's FOV image to the first entity's, and copy the first entity's ROIs, moved, to the others
%
%   With maxRotation, each image is also turned back by each angle from
%   -maxRotation to maxRotation in steps of rotationStep, and the angle of
%   largest correlation (the smallest, then the negative, of equal ones) is
%   taken. An ROI pixel p of the first entity goes to rotation(angle) * (p -
%   centre + shift) + centre, rounded half up, as in Python.
    if isempty(entities)
        nansen.internal.throwError("no-entities", "no entities to align")
    end
    reference = ophys.internal.fovImage(context.Project.load(entities{1}, options.image));
    [height, width] = size(reference);
    most = double(nansen.internal.getField(options, "maxRotation", 0));
    step = double(nansen.internal.getField(options, "rotationStep", 0.5));
    if most > 0 && step <= 0
        nansen.internal.throwError("invalid-options", "rotationStep is more than 0")
    end
    count = 0;
    if most > 0
        count = floor(most / step + 1e-9);
    end
    angles = (-count:count) * step;
    [~, order] = sortrows([abs(angles(:)), angles(:)]);
    angles = angles(order);
    tapered = most > 0;
    referenceFft = ophys.internal.referenceFft(reference, tapered);
    rows = ophys.internal.shiftRange(0, options.maxShift, options.maxShift, floor((height - 1) / 2));
    columns = ophys.internal.shiftRange(0, options.maxShift, options.maxShift, floor((width - 1) / 2));
    document = context.Project.load(entities{1}, options.rois);
    rois = ophys.internal.roiList(document);
    keep = cellfun(@(r) ~strcmp(string(nansen.internal.getField(r, "classification", "")), "rejected"), rois);
    rois = rois(keep);
    shifts = cell(1, numel(entities));
    migrated = 0;
    for number = 1:numel(entities)
        context.checkCancelled();
        entity = entities{number};
        image = ophys.internal.fovImage(context.Project.load(entity, options.image));
        if ~isequal(size(image), [height, width])
            nansen.internal.throwError("invalid-data", "%s: the image is %s, the reference %s", ...
                ophys.internal.entityName(entity), mat2str(size(image)), mat2str([height, width]))
        end
        best = -Inf;
        for angle = angles
            turned = image;
            if angle ~= 0
                turned = ophys.internal.rotateImage(image, angle);
            end
            if tapered
                turned = ophys.internal.tapered(turned);
            end
            correlation = ophys.internal.correlation(turned, referenceFft);
            [dy, dx] = ophys.internal.peak(correlation, [], rows, columns, false);
            value = correlation(mod(dy, height) + 1, mod(dx, width) + 1);
            if value > best
                best = value;
                shift = [dy, dx];
                rotation = angle;
            end
        end
        shifts{number} = struct("key", entity.Key, "shift", shift, "rotation", rotation);
        if number > 1
            moved = {};
            for i = 1:numel(rois)
                pixels = ophys.internal.rotatePoints(reshape(double(rois{i}.pixels), [], 2) + shift, rotation, height, width);
                pixels = unique(pixels(pixels(:, 1) >= 0 & pixels(:, 1) < height & pixels(:, 2) >= 0 & pixels(:, 2) < width, :), "rows");
                if ~isempty(pixels)
                    moved{end + 1} = ophys.internal.makeRoi(nansen.internal.getField(rois{i}, "id", numel(moved) + 1), pixels + 1); %#ok<AGROW>
                end
            end
            context.Project.save(entity, options.output, struct("imageSize", [height, width], "rois", {moved}));
            migrated = migrated + 1;
        end
        context.progress(number / numel(entities), ophys.internal.entityName(entity));
    end
    context.log("aligned %d entities to %s", numel(entities), ophys.internal.entityName(entities{1}));
    result = struct("reference", entities{1}.Key, "shifts", {shifts}, "migrated", migrated, "rois", numel(rois));
end
