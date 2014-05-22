unit ZentaoAPIUnit;

{$mode objfpc}{$H+}

interface

uses
    Classes, SysUtils,
    md5,
    fphttpclient,
    fpjson, jsonparser;

type
    { Record }

    UserConfig = record
        Url:      string;
        Account:  string;
        Password: string;
        PassMd5:  string;
        Role:     string;
    end;

    HandleResult = record
        Result:  boolean;
        Message: string;
        Sender:  TObject;
    end;

    PageRecord = record
        Status:     string;
        PageID:     integer;
        PageTotal:  integer;
        PerPage:    integer;
        Total:      integer;
        PageCookie: string;
    end;

    DataResult = record
        Result:  boolean;
        Message: string;
        Data:    TJSONObject;
        Pager:   PageRecord;
    end;

    BrowseType        = (btTodo = 0, btTask = 1, btBug = 2, btStory = 3);
    BrowseSubType     = (today = 0, yesterday = 1, thisweek = 2, lastweek =
        3, assignedTo = 4, openedBy = 5, reviewedBy = 6, closedBy = 7, finishedBy =
        8, resolvedBy = 9);

{ Function declarations }
procedure InitZentaoAPI();
procedure Destroy();
function GetAPI(const Params: array of const): string;
function CheckVersion(): HandleResult;
function GetConfig(): HandleResult;
function GetSession(): HandleResult;
function Login(): HandleResult;
function GetRole(): HandleResult;
function TryLogin(): HandleResult;
function Logout(): HandleResult;
function LoadDataList(obj: BrowseType; objType: BrowseSubType;
    pageID: string = ''): DataResult;
function Max(a: integer; b: integer): integer;
function Min(a: integer; b: integer): integer;

var
    user:           UserConfig;
    zentaoConfig:   TJSONObject;
    session:        TJSONObject;
    http:           TFPHTTPClient;
    BrowseName:     array[BrowseType] of string;
    BrowseTypes:    array[0..3] of BrowseType;
    BrowseSubName:  array[BrowseSubType] of string;
    BrowseSubTypes: array[0..9] of BrowseSubType;
    BrowsePagers:   array[BrowseType] of array[BrowseSubType] of PageRecord;

implementation

(* Load Data from server with zentao api and return in a list *)
function LoadDataList(obj: BrowseType; objType: BrowseSubType;
    pageID: string = ''): DataResult;
var
    response:  string;
    Data, pageData: TJSONObject;
    url:       string;
    pager:     PageRecord;
    pageNum:   integer;
    firstPage: boolean;
begin
    Result.Result := True;

    (* init page *)
    pager  := BrowsePagers[obj, objType];
    pageID := LowerCase(pageID);
    if pager.status = 'ok' then
    begin
        if (pageID = 'next') or (pageID = 'n') then
        begin
            pageID := IntToStr(Max(pager.PageID + 1, pager.PageTotal));
        end
        else if (pageID = 'prev') or (pageID = 'p') then
        begin
            pageID := IntToStr(Min(pager.PageID - 1, pager.PageTotal));
        end
        else if (pageID = 'last') or (pageID = 'l') then
        begin
            pageID := IntToStr(pager.PageTotal);
        end
        else if (pageID = 'first') or (pageID = 'f') then
        begin
            pageID := '';
        end
        else
        begin
            try
                pageID := IntToStr(StrToInt(pageID));
            except
                pageID := '';
            end;
        end;
    end
    else
    begin
        pageID := '';
    end;
    firstPage := (pageID = '');

    (* get url *)
    url := GetAPI(['module', 'my', 'method', BrowseName[obj],
        'type', BrowseSubName[objType], 'pageID', pageID, 'recTotal',
        IntToStr(pager.Total), 'recPerPage', IntToStr(pager.PerPage)]);
    Result.Message := 'Loading: ' + url;

    try
        response := http.Get(url);
        try
            (* prepare data *)
            Data     := TJSONObject(TJSONParser.Create(response).Parse);
            response := Data.Get('data', '');
            if response <> '' then
                Data := TJSONObject(TJSONParser.Create(response).Parse);

            pageData := Data.Objects['pager'];

            pager.PageID := pageData.Get('pageID', 1);
            if pager.PageID = 1 then
                pager.PageID := StrToInt(pageData.Get('pageID', '1'));
            if firstPage then
            begin
                pager.status     := 'ok';
                pager.PerPage    := pageData.Get('recPerPage', 20);
                pager.PageTotal  := pageData.Get('pageTotal', 0);
                pager.PageCookie := pageData.Get('pageCookie', '');
                pager.Total      := pageData.Get('recTotal', 0);
            end;
            Result.Pager := pager;
            BrowsePagers[obj, objType] := pager;


            Result.Data := Data;
        except
            Result.Result  := False;
            Result.Message := '服务器返回的数据不正确。 URL: ' + url;
        end;
    except
        Result.Result  := False;
        Result.Message := '无法连接到服务器。';
    end;
end;

(* Get config *)
function GetConfig(): HandleResult;
var
    configStr: string;
begin
    Result.Result := True;
    try
        configStr := http.Get(user.Url + '/index.php?mode=getconfig');
        if Length(configStr) > 0 then
        begin
            zentaoConfig := TJSONObject(TJSONParser.Create(configStr).Parse);
        end
        else
            Result.Result := False;
    except
        Result.Result := False;
    end;
    if not Result.Result then
        Result.Message := '无法获取禅道配置信息。';
end;

(* Check version *)
function CheckVersion(): HandleResult;
var
    version: string;
    verNum:  extended;
    isPro:   boolean;
begin
    version := zentaoConfig.Strings['version'];
    isPro   := False;

    if Pos('pro', LowerCase(version)) > 0 then
    begin
        isPro   := True;
        version := StringReplace(version, 'pro', '', [rfReplaceAll]);
    end;

    verNum        := StrToFloat(version);
    Result.Result := False;

    if isPro and (verNum <= 1.3) then
    begin
        Result.Message := Format('您当前版本是%s，请升级至%s以上版本', [version, 'pro1.3']);
    end
    else if not isPro and (verNum < 4) then
    begin
        Result.Message := Format('您当前版本是%s，请升级至%s以上版本', [version, '4.0']);
    end
    else
        Result.Result := True;
end;

(* Get API address *)
function GetAPI(const Params: array of const): string;
var
    config:  TJSONObject;
    viewType, moduleName, methodName, password, pageID: string;
    item:    TJSONEnum;
    nameSet: TStringList;
begin
    config     := TJSONObject.Create(Params);
    viewType   := config.Get('viewType', 'json');
    moduleName := config.Get('module', '');
    methodName := config.Get('method', '');
    nameSet    := TStringList.Create;
    nameSet.CommaText :=
        'viewType,module,method,moduleName,methodName,pageID,type,recTotal,recPerPage';

    if LowerCase(zentaoConfig.Get('requestType', '')) = 'get' then
    begin
        Result := user.Url + '/index.php?';
        if (moduleName = 'user') and (methodName = 'login') then
        begin
            password := MD5Print(MD5String(user.Password +
                IntToStr(session.Int64s['rand'])));
            Result   := Result + 'm=user&f=login&account=' + user.Account +
                '&password=' + password + '&' + session.Get('sessionName', '') +
                '=' + session.Get('sessionID', '') + '&t=json';
            Exit;
        end;

        Result := Result + 'm=' + moduleName + '&f=' + methodName;

        if (moduleName = 'api') and (LowerCase(methodName) = 'getmodel') then
        begin
            Result := Result + '&moduleName=' + config.Get('moduleName', '') +
                '&methodName=' + config.Get('methodName', '') + '&params=';
            for item in config do
            begin
                if (nameSet.indexOf(item.Key) > 0) then
                    continue;
                Result := Result + item.Key + '=' + item.Value.AsString + '&';
            end;
        end;

        if moduleName = 'my' then
            Result := Result + '&type=' + config.Get('type', '');
        if methodName = 'view' then
            Result := Result + '&' + moduleName + 'ID=' + config.Get('ID', '');

        pageID := config.Get('pageID', '');
        if pageID <> '' then
        begin
            if methodName = 'todo' then
            begin
                Result := Result +
                    '&account=&status=all&orderBy=date_desc,status,begin&';
            end
            else
            begin
                // Result := Result + '&orderBy=id_desc&recTotal=' + pager.recTotal + '&recPerPage=' + pager.recPerPage + '&pageID=' + pageID;
            end;
        end;

        Result := Result + '&t=' + viewType;

        if not session.Get('undefined', False) then
        begin
            Result := Result + '&' + session.Get('sessionName', '') +
                '=' + session.Get('sessionID', '');
        end;
    end
    else
    begin
        Result := Result + user.Url + '/';
        if (moduleName = 'user') and (methodName = 'login') then
        begin
            password := MD5Print(MD5String(user.PassMd5 +
                IntToStr(session.Int64s['rand'])));
            Result   := Result + 'user-login.json?account=' +
                user.Account + '&password=' + password + '&' +
                session.Get('sessionName', 'sid') + '=' + session.Get('sessionID', '');
            Exit;
        end;

        Result := Result + moduleName + '-' + methodName + '-';

        if (moduleName = 'api') and (LowerCase(methodName) = 'getmodel') then
        begin
            Result := Result + config.Get('moduleName', '') + '-' +
                config.Get('methodName', '') + '-';
        end;

        if moduleName = 'my' then
            Result := Result + config.Get('type', '') + '-';

        for item in config do
        begin
            if (nameSet.indexOf(item.Key) > 0) then
                continue;
            Result := Result + item.Key + '=' + item.Value.AsString + '-';
        end;

        pageID := config.Get('pageID', '');
        if pageID <> '' then
        begin
            if methodName = 'todo' then
            begin
                Result := Result + '-all-date_desc,status,begin-';
            end
            else
            begin
                Result := Result + '-id_desc-';
            end;
            Result := Result + config.Get('recTotal', '') + '-' +
                config.Get('recPerPage', '') + '-' + pageID;
        end;

        if Result[Length(Result)] = '-' then
            Result := Copy(Result, 1, Length(Result) - 1);

        Result := Result + '.' + viewType;

        if not session.Get('undefined', False) then
        begin
            Result := Result + '?' + session.Get('sessionName', '') +
                '=' + session.Get('sessionID', '');
        end;
    end;
end;

(* Get session *)
function GetSession: HandleResult;
var
    sessionStr: string;
begin
    Result.Result := True;
    try
        sessionStr := http.Get(GetAPI(['module', 'api', 'method', 'getSessionID']));
        if Length(sessionStr) > 0 then
        begin
            session := TJSONObject(TJSONParser.Create(sessionStr).Parse);
            if session.Get('status', '') = 'success' then
            begin
                sessionStr := session.Get('data', '');
                session    := TJSONObject(TJSONParser.Create(sessionStr).Parse);
            end
            else
                Result.Result := False;
        end
        else
            Result.Result := False;
    except
        Result.Result := False;
    end;

    if not Result.Result then
        Result.Message := '无法获取Session。';
end;

(* Login *)
function Login(): HandleResult;
var
    response: string;
    status:   TJSONObject;
begin
    Result.Result := True;
    try
        response := http.Get(GetAPI(['module', 'user', 'method', 'login']));
        if Length(response) > 0 then
        begin
            status := TJSONObject(TJSONParser.Create(response).Parse);
            if status.get('status', '') = 'failed' then
            begin
                Result.Result := False;
            end;
        end
        else
            Result.Result := False;
    except
        Result.Result := False;
    end;
    if not Result.Result then
        Result.Message := '登录失败。请检查用户名和密码。';
end;

(* Get role *)
function GetRole(): HandleResult;
var
    response: string;
    role:     TJSONObject;
begin
    Result.Result := True;
    try
        response := http.Get(GetAPI(['module', 'api', 'method', 'getmodel',
            'moduleName', 'user', 'methodName', 'getById', 'account', user.Account]));
        if Length(response) > 0 then
        begin
            role := TJSONObject(TJSONParser.Create(response).Parse);
            if role.get('status', '') = 'failed' then
            begin
                Result.Result := False;
            end
            else
            begin
                role      := TJSONObject(TJSONParser.Create(role.Get('data', '')).Parse);
                user.Role := role.Get('role', '');
            end;
        end
        else
            Result.Result := False;
    except
        Result.Result := False;
    end;

    if not Result.Result then
        Result.Message := '获取角色信息失败。';
end;

function Logout(): HandleResult;
var
    url, response: string;
begin
    Result.Result := True;
    url           := GetAPI(['module', 'user', 'method', 'logout']);

    try
        http.Get(url);
    except
        Result.Result  := False;
        Result.Message := '注销时发生了错误。 Url: ' + url + '||' + response;
    end;
end;

(* Try login in *)
function TryLogin(): HandleResult;
begin
    session := TJSONObject.Create(['undefined', True]);

    Result := GetConfig();
    if not Result.Result then
        Exit;

    //Result := CheckVersion();
    //if not Result.Result then
    //   Exit;

    Result := GetSession();
    if not Result.Result then
        Exit;

    Result := Login();
    if not Result.Result then
        Exit;

    Result := GetRole();
    if not Result.Result then
        Exit;
end;

procedure InitZentaoAPI();
begin
    http := TFPHTTPClient.Create(nil);

    (* init browsename *)
    BrowseName[btTodo]  := 'todo';
    BrowseName[btTask]  := 'task';
    BrowseName[btBug]   := 'bug';
    BrowseName[btStory] := 'story';

    BrowseTypes[0] := btTodo;
    BrowseTypes[1] := btTask;
    BrowseTypes[2] := btBug;
    BrowseTypes[3] := btStory;

    BrowseSubName[today]      := 'today';
    BrowseSubName[yesterday]  := 'yesterday';
    BrowseSubName[thisweek]   := 'thisweek';
    BrowseSubName[lastweek]   := 'lastweek';
    BrowseSubName[assignedTo] := 'assignedTo';
    BrowseSubName[openedBy]   := 'openedBy';
    BrowseSubName[reviewedBy] := 'reviewedBy';
    BrowseSubName[closedBy]   := 'closedBy';
    BrowseSubName[finishedBy] := 'finishedBy';
    BrowseSubName[resolvedBy] := 'resolvedBy';

    BrowseSubTypes[0] := today;
    BrowseSubTypes[1] := yesterday;
    BrowseSubTypes[2] := thisweek;
    BrowseSubTypes[3] := lastweek;
    BrowseSubTypes[4] := assignedTo;
    BrowseSubTypes[5] := openedBy;
    BrowseSubTypes[6] := reviewedBy;
    BrowseSubTypes[7] := closedBy;
    BrowseSubTypes[8] := finishedBy;
    BrowseSubTypes[9] := resolvedBy;
end;

procedure Destroy();
begin
    http.Free;
end;

function Max(a: integer; b: integer): integer;
begin
    if a > b then
    begin
        Result := a;
    end
    else
    begin
        Result := b;
    end;
end;

function Min(a: integer; b: integer): integer;
begin
    if a < b then
    begin
        Result := a;
    end
    else
    begin
        Result := b;
    end;
end;

end.