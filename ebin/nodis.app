%% -*- erlang -*-
{application, nodis,
 [{description,"Node discovery over multicast"},
  {vsn, "1.0"},
  {modules, [nodis, nodis_app, nodis_sup, nodis_srv]},
  {registered, [nodis_srv, nodis_sup]},
  {mod, {nodis_app, []}},
  {applications, [kernel, stdlib]}]}.
