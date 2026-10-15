function result = alignSessions(entities, options, context)
%alignSessions Align each entity's FOV image to the first entity's, and copy the first entity's ROIs, moved, to the others
    if isempty(entities)
        nansen.internal.throwError("no-entities", "no entities to align")
    end
    reference = ophys.internal.fovImage(context.Project.load(entities{1}, options.image));
    [height, width] = size(reference);
    referenceFft = conj(fft2(reference)) .* ophys.internal.smoothing(height, width);
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
        shift = ophys.internal.estimateShifts(image, referenceFft, options.maxShift);
        shifts{number} = struct("key", entity.Key, "shift", shift);
        if number > 1
            moved = {};
            for i = 1:numel(rois)
                pixels = reshape(double(rois{i}.pixels), [], 2) + shift;
                pixels = sortrows(pixels(pixels(:, 1) >= 0 & pixels(:, 1) < height & pixels(:, 2) >= 0 & pixels(:, 2) < width, :));
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
