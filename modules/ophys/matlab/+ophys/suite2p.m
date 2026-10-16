function result = suite2p(entity, options, context)
%suite2p Run the MATLAB Suite2P (cortex-lab/Suite2P), when it is on the path, and keep its cells as ROIs with their signals and spikes
%
%   As dev's suite2p workflow (nansen.wrapper.suite2p, which ran Suite2P's
%   sourcery), but through Suite2P's whole pipeline, as its run_pipeline and
%   add_deconvolution (ophys.internal.runSuite2p): registration by reg2P
%   (with registration), cells by sourcery, signals and surround neuropil by
%   extractSignalsSurroundNeuropil2, cells told by classifyROI, and spikes by
%   wrapperDECONV (OASIS, whose oasisAR1 CaImAn-MATLAB has) of each signal
%   less neuropilCoefficient times its neuropil. The options go to Suite2P
%   under its names (ophys.internal.suite2pOps). Suite2P's results file and
%   input.tif are kept in a suite2p folder next to the ROI file, as Python's
%   ophys_methods.suite2p keeps suite2p's output. Suite2P uses the Image
%   Processing, Signal Processing and Statistics toolboxes.
%
%   The MATLAB Suite2P has no sparse mode (it finds cells with sourcery
%   only), so with sparseMode the method runs in Python's suite2p instead,
%   with these options (spatialScale and denoise too): as a task for Python
%   run now by a Python with nansen-core and suite2p
%   (nansen.internal.runInPython), so its results are Python's. Without
%   such a Python that is dependency-missing; turn sparseMode off to run the
%   MATLAB Suite2P.
    if isequal(nansen.internal.getField(options, "sparseMode", false), true)
        if ~isa(context.Project, "nansen.Project")
            nansen.internal.throwError("method-unavailable", ...
                "ophys.suite2p's sparse mode runs Python's suite2p on a project's entity, as a task, which a preview or a stack viewed without a project cannot; turn sparseMode off to run the MATLAB Suite2P (sourcery)")
        end
        context.log("%s: sparse mode is suite2p's in Python: running ophys.suite2p there", ophys.internal.entityName(entity));
        result = nansen.internal.runInPython(context.Project, "ophys.suite2p", {entity}, options, ...
            Hint="or turn sparseMode off to run the MATLAB Suite2P (sourcery)");
        context.log("%s: suite2p in Python kept %d ROIs", ophys.internal.entityName(entity), ...
            round(double(nansen.internal.getField(result, "rois", 0))));
        return
    end
    needed = ["build_ops3", "reg2P", "sourcery", "extractSignalsSurroundNeuropil2", "classifyROI", ...
        "get_clustrules", "opsChanges", "wrapperDECONV"];
    if ~all(arrayfun(@(name) exist(name, "file") == 2, needed))
        nansen.internal.throwError("dependency-missing", ...
            "ophys.suite2p needs the MATLAB Suite2P on the MATLAB path: https://github.com/cortex-lab/Suite2P")
    end
    spikes = strlength(string(options.spikesOutput)) > 0;
    if spikes && exist("oasisAR1", "file") ~= 2
        nansen.internal.throwError("dependency-missing", ...
            "ophys.suite2p deconvolves with OASIS (oasisAR1), of CaImAn-MATLAB (https://github.com/flatironinstitute/CaImAn-MATLAB) " + ...
            "or OASIS_matlab; leave spikesOutput empty to not deconvolve")
    end
    stack = ophys.internal.loadStack(context, entity, options.stack, options);
    [height, width, frames] = size(stack);
    folder = fullfile(fileparts(context.Project.writePath(entity, options.rois)), "suite2p");
    if ~isfolder(folder)
        mkdir(folder);
    end
    ophys.TiffStack().write(fullfile(folder, "input.tif"), stack);
    ops = ophys.internal.suite2pOps(options, frames, ophys.internal.extractGpu());
    context.log("%s: running Suite2P in %s", ophys.internal.entityName(entity), folder);
    out = ophys.internal.runSuite2p(stack, ops, char(folder), logical(options.registration), ...
        double(options.neuropilCoefficient), spikes);
    keep = ~cellfun(@isempty, out.pixels);
    if options.onlyCells
        keep = keep & out.iscell;
    end
    rois = {};
    for k = find(keep)
        rois{end + 1} = ophys.internal.makeRoi(numel(rois) + 1, sortrows(out.pixels{k})); %#ok<AGROW>
    end
    context.Project.save(entity, options.rois, struct("imageSize", [height, width], "rois", {rois}));
    ophys.internal.saveIf(context, entity, options.output, out.F(:, keep));
    ophys.internal.saveIf(context, entity, options.neuropilOutput, out.Fneu(:, keep));
    if spikes
        ophys.internal.saveIf(context, entity, options.spikesOutput, out.spikes(:, keep));
    end
    context.log("%s: Suite2P kept %d of %d ROIs", ophys.internal.entityName(entity), numel(rois), numel(out.pixels));
    result = struct("rois", numel(rois), "frames", frames);
end
