function result = flufinder(entity, options, context)
%flufinder Detect ROIs with dev's flufinder (Quicky's algorithm), when it is on the path
%
%   Runs flufinder.runAutoSegmentation from NANSEN dev on the stack and
%   saves its ROIs, from each RoI's mask, in the ROI file format.
    if isempty(which("flufinder.runAutoSegmentation"))
        nansen.internal.throwError("dependency-missing", ...
            "ophys.flufinder needs flufinder from NANSEN dev on the MATLAB path: https://github.com/VervaekeLab/NANSEN")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    context.log("%s: running flufinder on %d frames", ophys.internal.entityName(entity), frames);
    found = feval("flufinder.runAutoSegmentation", stack, "RoiDiameter", options.roiDiameter);
    rois = {};
    for i = 1:numel(found)
        [columns, rows] = find(found(i).mask.');   % row-major
        if ~isempty(rows)
            rois{end + 1} = ophys.internal.makeRoi(numel(rois) + 1, [rows, columns]); %#ok<AGROW>
        end
    end
    ophys.internal.saveIf(context, entity, options.output, struct("imageSize", [height, width], "rois", {rois}));
    result = struct("rois", numel(rois), "frames", frames);
end
