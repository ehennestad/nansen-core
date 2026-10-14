classdef App < handle
%App The NANSEN app in MATLAB: one uihtml showing the HTML/JS frontend, talking to nansen.Api
%
%   app = nansen.App() opens the app with the user's project catalog.
%   app = nansen.App(Project=folder) opens a project. The frontend sends
%   requests with sendEventToMATLAB("request", json); the app answers with
%   sendEventToHTMLSource(..., "response", json) and pushes core events as
%   "event". Tasks run on backgroundPool, polled by a timer. Needs R2023a+.

    properties (SetAccess = private)
        Figure
        Html
        Api
    end

    properties (Access = private)
        Unsubscribe = []
    end

    methods
        function obj = App(options)
            arguments
                options.Project = []
                options.CatalogPath (1,1) string = nansen.Catalog.defaultPath()
                options.Visible (1,1) logical = true
                options.StartQueue (1,1) logical = true
            end
            obj.Api = nansen.Api(Catalog=nansen.Catalog(options.CatalogPath));
            if ~isempty(options.Project)
                folder = options.Project;
                if isa(folder, "nansen.Project")
                    folder = folder.Folder;
                end
                response = obj.Api.handle(struct("id", 0, "method", "project.open", ...
                    "params", struct("path", char(folder))));
                if isfield(response, "error")
                    error("nansen:App:CannotOpen", "%s", response.error.message)
                end
                if options.StartQueue
                    obj.Api.handle(struct("id", 0, "method", "queue.start"));
                end
            end
            obj.Figure = uifigure(Name="NANSEN", Position=[80 80 1440 880], Visible=options.Visible, ...
                CloseRequestFcn=@(~, ~) obj.close());
            grid = uigridlayout(obj.Figure, [1 1], Padding=0);
            obj.Html = uihtml(grid, HTMLSource=fullfile(nansen.internal.repoRoot(), "ui", "index.html"), ...
                HTMLEventReceivedFcn=@(~, event) obj.onHtmlEvent(event));
            obj.Unsubscribe = obj.Api.subscribe(@(message) obj.push(message));
        end

        function close(obj)
            if ~isempty(obj.Unsubscribe)
                obj.Unsubscribe();
                obj.Unsubscribe = [];
            end
            if ~isempty(obj.Api) && isvalid(obj.Api)
                delete(obj.Api);
            end
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                delete(obj.Figure);
            end
        end

        function delete(obj)
            obj.close();
        end
    end

    methods (Access = private)
        function onHtmlEvent(obj, event)
            if string(event.HTMLEventName) ~= "request"
                return
            end
            text = obj.Api.handleJson(event.HTMLEventData);
            sendEventToHTMLSource(obj.Html, "response", char(text));
        end

        function push(obj, message)
            if ~isempty(obj.Html) && isvalid(obj.Html)
                sendEventToHTMLSource(obj.Html, "event", jsonencode(message));
            end
        end
    end
end
