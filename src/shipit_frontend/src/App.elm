port module App exposing (..)

import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Html.App
import Http
import String
import Json.Decode as JsonDecode exposing ((:=))
import RouteUrl exposing (UrlChange)
import RouteUrl.Builder as Builder exposing (Builder, builder, replacePath)
import RemoteData exposing (WebData, RemoteData(..))
import Navigation exposing (Location)
import BugzillaLogin as Bugzilla
import TaskclusterLogin as User
import Hawk
import Utils
import App.Utils exposing (eventLink)
import App.Home as Home
import App.ReleaseDashboard as ReleaseDashboard


type Page
    = Home
    | ReleaseDashboard
    | Bugzilla


type
    Msg
    -- Extensions integration
    = BugzillaMsg Bugzilla.Msg
    | UserMsg User.Msg
    | HawkRequest Hawk.Msg
      -- App code
    | ShowPage Page
    | ReleaseDashboardMsg ReleaseDashboard.Msg


type alias Role =
    { roleId : String
    , scopes : List String
    }


type alias Model =
    { -- Extensions integration
      user : User.Model
    , bugzilla :
        Bugzilla.Model
        -- App code
    , current_page : Page
    , release_dashboard : ReleaseDashboard.Model
    }


type alias Flags =
    { taskcluster : Maybe (User.Credentials)
    , bugzilla : Maybe (Bugzilla.Credentials)
    , backend_dashboard_url : String
    , bugzilla_url : String
    }


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        -- Extensions integration
        ( bz, bzCmd ) =
            Bugzilla.init flags.bugzilla_url flags.bugzilla

        ( user, userCmd ) =
            User.init flags.taskcluster

        -- App init
        ( dashboard, newCmd ) =
            ReleaseDashboard.init flags.backend_dashboard_url

        model =
            { bugzilla = bz
            , user = user
            , current_page = Home
            , release_dashboard = dashboard
            }
    in
        ( model
        , -- Follow through with sub parts init
          Cmd.batch
            [ -- Extensions integration
              Cmd.map BugzillaMsg bzCmd
            , Cmd.map UserMsg userCmd
            , loadAllAnalysis model
            ]
        )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- Extensions integration
        BugzillaMsg bzMsg ->
            let
                ( newBz, bzCmd ) =
                    Bugzilla.update bzMsg model.bugzilla
            in
                ( { model | bugzilla = newBz }
                , Cmd.map BugzillaMsg bzCmd
                )

        UserMsg userMsg ->
            let
                -- Update current user
                ( user, userCmd ) =
                    User.update userMsg model.user

                l =
                    Debug.log "new user" user

                -- Load analysis on user login
                commands =
                    List.concat
                        [ [ Cmd.map UserMsg userCmd ]
                        , case userMsg of
                            User.Logged _ ->
                                [ loadAllAnalysis model ]

                            _ ->
                                []
                        ]
            in
                ( { model | user = user }, Cmd.batch commands )

        HawkRequest hawkMsg ->
            let
                -- Always Redirect to release dashboard
                -- If we need another module, a prefix in requestId would be needed
                ( requestId, cmd, response ) =
                    Hawk.update hawkMsg

                dashboardCmd =
                    requestId
                        |> Maybe.map (ReleaseDashboard.routeHawkRequest response)
                        |> Maybe.withDefault Cmd.none
            in
                ( model
                , Cmd.batch
                    [ Cmd.map HawkRequest cmd
                    , Cmd.map ReleaseDashboardMsg dashboardCmd
                    ]
                )

        -- Routing
        ShowPage page ->
            ( { model | current_page = page }, Cmd.none )

        -- Dashboard updates
        ReleaseDashboardMsg dashMsg ->
            let
                ( dashboard, cmd ) =
                    ReleaseDashboard.update dashMsg model.release_dashboard model.user model.bugzilla
            in
                ( { model | release_dashboard = dashboard, current_page = ReleaseDashboard }
                , Cmd.map ReleaseDashboardMsg cmd
                )


loadAllAnalysis : Model -> Cmd Msg
loadAllAnalysis model =
    -- (Re)Load all dashboard analysis
    -- when user is loaded or is logged in
    case model.user of
        Just user ->
            Cmd.map ReleaseDashboardMsg (ReleaseDashboard.fetchAllAnalysis model.release_dashboard model.user)

        Nothing ->
            Cmd.none



-- Demo view


view : Model -> Html Msg
view model =
    div []
        [ nav [ id "navbar", class "navbar navbar-full navbar-dark bg-inverse" ]
            [ div [ class "container-fluid" ] (viewNavBar model)
            ]
        , div [ id "content" ]
            [ case model.user of
                Just user ->
                    div [ class "container-fluid" ]
                        [ viewDashboardStatus model.release_dashboard
                        , viewPage model
                        ]

                Nothing ->
                    div [ class "container" ]
                        [ div [ class "alert alert-warning" ]
                            [ text "Please login first."
                            ]
                        ]
            ]
        , viewFooter
        ]


viewPage model =
    case model.current_page of
        Home ->
            Home.view model

        Bugzilla ->
            Html.App.map BugzillaMsg (Bugzilla.view model.bugzilla)

        ReleaseDashboard ->
            Html.App.map ReleaseDashboardMsg (ReleaseDashboard.view model.release_dashboard model.bugzilla)


viewNavBar model =
    [ button
        [ class "navbar-toggler hidden-md-up"
        , type' "button"
        , attribute "data-toggle" "collapse"
        , attribute "data-target" ".navbar-collapse"
        , attribute "aria-controls" "navbar-header"
        ]
        [ text "Menu" ]
    , pageLink Home
        [ class "navbar-brand" ]
        [ text "Uplift Dashboard" ]
    , div [ class "user collapse navbar-toggleable-sm navbar-collapse" ]
        [ ul [ class "nav navbar-nav" ]
            (List.concat
                [ viewNavDashboard model
                , [ li [ class "nav-item float-xs-right" ] (viewUser model) ]
                ]
            )
        ]
    ]


viewUser model =
    case model.user of
        Just user ->
            viewDropdown user.clientId
                [ -- Link to TC manager
                  a
                    [ class "dropdown-item"
                    , href "https://tools.taskcluster.net/credentials"
                    , target "_blank"
                    ]
                    [ text "Manage credentials" ]
                  -- Display bugzilla status
                , viewBugzillaCreds model.bugzilla
                , -- Logout from TC
                  div [ class "dropdown-divider" ] []
                , a
                    [ Utils.onClick (UserMsg User.Logout)
                    , href "#"
                    , class "dropdown-item"
                    ]
                    [ text "Logout" ]
                ]

        Nothing ->
            viewLogin


viewBugzillaCreds : Bugzilla.Model -> Html Msg
viewBugzillaCreds bugzilla =
    case bugzilla.check of
        NotAsked ->
            a [ class "dropdown-item text-info" ]
                [ span [] [ text "No bugzilla auth" ]
                , span [] viewLoginBugzilla
                ]

        Loading ->
            a [ class "dropdown-item text-info disabled" ] [ text "Loading Bugzilla auth." ]

        Failure err ->
            a [ class "dropdown-item text-danger" ]
                [ span [] [ text ("Error while loading bugzilla auth: " ++ toString err) ]
                , span [] viewLoginBugzilla
                ]

        Success valid ->
            if valid then
                a [ class "dropdown-item text-success disabled" ] [ text "Valid bugzilla auth" ]
            else
                a [ class "dropdown-item text-danger" ]
                    [ span [] [ text "Invalid bugzilla auth" ]
                    , span [] viewLoginBugzilla
                    ]


viewLoginBugzilla =
    [ eventLink (ShowPage Bugzilla) [ class "nav-link" ] [ text "Login Bugzilla" ]
    ]


viewNavDashboard : Model -> List (Html Msg)
viewNavDashboard model =
    case model.release_dashboard.all_analysis of
        NotAsked ->
            []

        Loading ->
            [ li [ class "nav-item text-info" ] [ text "Loading Bugs analysis..." ]
            ]

        Failure err ->
            [ li [ class "nav-item text-danger" ] [ text "No analysis available." ]
            ]

        Success allAnalysis ->
            (List.map viewNavAnalysis allAnalysis)


viewDashboardStatus : ReleaseDashboard.Model -> Html Msg
viewDashboardStatus dashboard =
    -- Display explicit error messages
    case dashboard.all_analysis of
        Failure err ->
            div [ class "alert alert-danger" ]
                [ h4 [] [ text "Error while loading analysis" ]
                , case err of
                    Http.Timeout ->
                        span [] [ text "A timeout occured during the request." ]

                    Http.NetworkError ->
                        span [] [ text "A network error occuring during the request, check your internet connectivity." ]

                    Http.UnexpectedPayload data ->
                        let
                            l =
                                Debug.log "Unexpected payload: " data
                        in
                            span [] [ text "An unexpected payload was received, check your browser logs" ]

                    Http.BadResponse code message ->
                        case code of
                            401 ->
                                p []
                                    ([ p [] [ text "You are not authenticated: please login again." ]
                                     ]
                                        ++ viewLogin
                                    )

                            _ ->
                                span [] [ text ("The backend produced an error " ++ (toString code) ++ " : " ++ message) ]
                ]

        _ ->
            div [] []


viewNavAnalysis : ReleaseDashboard.Analysis -> Html Msg
viewNavAnalysis analysis =
    li [ class "nav-item analysis" ]
        [ analysisLink analysis.id
            [ class "nav-link" ]
            [ span [ class "name" ] [ text (analysis.name ++ " " ++ (toString analysis.version)) ]
            , if analysis.count > 0 then
                span [ class "tag tag-pill tag-primary" ] [ text (toString analysis.count) ]
              else
                span [ class "tag tag-pill tag-success" ] [ text (toString analysis.count) ]
            ]
        ]


viewLogin =
    [ a
        [ Utils.onClick
            (User.redirectToLogin
                UserMsg
                "/login"
                "Uplift dashboard helps Mozilla Release Management team in their workflow."
            )
        , href "#"
        , class "nav-link"
        ]
        [ text "Login TaskCluster" ]
    ]


viewFooter =
    footer []
        [ ul []
            [ li [] [ a [ href "https://github.com/mozilla-releng/services" ] [ text "Github" ] ]
            , li [] [ a [ href "#" ] [ text "Contribute" ] ]
            , li [] [ a [ href "#" ] [ text "Contact" ] ]
              -- TODO: add version / revision
            ]
        ]


viewDropdown title pages =
    [ div [ class "dropdown" ]
        [ a
            [ class "nav-link dropdown-toggle btn btn-primary"
            , id ("dropdown" ++ title)
            , href "#"
            , attribute "data-toggle" "dropdown"
            , attribute "aria-haspopup" "true"
            , attribute "aria-expanded" "false"
            ]
            [ text title ]
        , div
            [ class "dropdown-menu dropdown-menu-right"
            , attribute "aria-labelledby" "dropdownServices"
            ]
            pages
        ]
    ]



-- Routing


pageLink page attributes =
    eventLink (ShowPage page) attributes


analysisLink analysis attributes =
    eventLink (ReleaseDashboardMsg (ReleaseDashboard.FetchAnalysis analysis)) attributes


location2messages : Location -> List Msg
location2messages location =
    let
        builder =
            Builder.fromUrl location.href
    in
        case Builder.path builder of
            first :: rest ->
                -- Extensions integration
                case first of
                    "login" ->
                        [ Builder.query builder
                            |> User.convertUrlQueryToUser
                            |> Maybe.map
                                (\x ->
                                    x
                                        |> User.Logging
                                        |> UserMsg
                                )
                            |> Maybe.withDefault (ShowPage Home)
                        , ShowPage Home
                        ]

                    "bugzilla" ->
                        [ ShowPage Bugzilla
                        ]

                    "release-dashboard" ->
                        let
                            messages =
                                if List.length rest == 1 then
                                    case List.head rest of
                                        Just analysisId ->
                                            case String.toInt analysisId |> Result.toMaybe of
                                                Just analysisId' ->
                                                    -- Load specified analysis
                                                    [ ReleaseDashboardMsg (ReleaseDashboard.FetchAnalysis analysisId') ]

                                                Nothing ->
                                                    []

                                        -- not a string
                                        Nothing ->
                                            []
                                    -- empty string
                                else
                                    []

                            -- No sub query parts
                        in
                            -- Finish by showing the page
                            messages ++ [ ShowPage ReleaseDashboard ]

                    _ ->
                        [ ShowPage Home ]

            _ ->
                [ ShowPage Home ]


delta2url : Model -> Model -> Maybe UrlChange
delta2url previous current =
    Maybe.map Builder.toUrlChange <|
        case current.current_page of
            ReleaseDashboard ->
                let
                    path =
                        case current.release_dashboard.current_analysis of
                            Success analysis ->
                                [ "release-dashboard", (toString analysis.id) ]

                            _ ->
                                [ "release-dashboard" ]
                in
                    Maybe.map
                        (Builder.prependToPath path)
                        (Just builder)

            Bugzilla ->
                Maybe.map
                    (Builder.prependToPath [ "bugzilla" ])
                    (Just builder)

            _ ->
                Maybe.map
                    (Builder.prependToPath [])
                    (Just builder)



-- Subscriptions


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ -- Extensions integration
          Sub.map BugzillaMsg (Bugzilla.bugzillalogin_get (Bugzilla.Logged))
        , Sub.map UserMsg (User.taskclusterlogin_get (User.Logged))
        , Sub.map HawkRequest (Hawk.hawk_send_request (Hawk.SendRequest))
        ]
