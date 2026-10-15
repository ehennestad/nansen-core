function app = view(data, options)
%view Open the app's viewer on image stacks or signals, with no project
%
%   As dev's command-line viewers: nansen.view(array) and
%   nansen.view("recording.tif") as imviewer; nansen.view([],
%   Signals=traces) as signalviewer (frames x N); nansen.view(file,
%   Rois="rois.json") shows ROIs over the stack, read only, as
%   roimanager. data is a file any stack adapter reads (TIFF, .npy,
%   SciScan raw, HDF5, video, ...) or an array, height x width (x channels
%   (x planes)) x frames, or a cell array of them. Signals are an array, a
%   .npy file or a .mat file (Variable names the variable, when it has
%   more than one numeric array). Rois is an ROI file (.json as ophys saves
%   ROIs, or dev's roimanager .mat) or an ROI struct. FrameRate (frames per
%   second) is used when the files do not tell one.
%
%   Returns the nansen.App, opened straight into the viewer. Only what is
%   given here can be read by the page (nansen.Viewables): the app's
%   view.frame, view.signal and view.traces serve nothing else. Python's
%   nansen.view and `nansen view <file>` do the same.
    arguments
        data = []
        options.Rois = []
        options.Signals = []
        options.Name (1,1) string = ""
        options.Adapter (1,1) string = ""
        options.Variable (1,1) string = ""
        options.FrameRate = []
        options.CatalogPath (1,1) string = nansen.Catalog.defaultPath()
        options.Visible (1,1) logical = true
    end
    viewables = nansen.Viewables();
    viewables.register(data, Rois=options.Rois, Signals=options.Signals, Name=options.Name, ...
        Adapter=options.Adapter, Variable=options.Variable, FrameRate=options.FrameRate);
    listed = viewables.list();
    app = nansen.App(Viewables=viewables, CatalogPath=options.CatalogPath, Visible=options.Visible, ...
        StartQueue=false, Name="NANSEN · " + string(listed{1}.name));
end
