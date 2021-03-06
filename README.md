HarmonyX
========

iOS app and today extension (aka widget) for controlling the Logitech Harmony Hub.

Based on the work done to reverse engineer and implement the Logitech Harmony Hub communications protocol in the following projects:

* https://github.com/jterrace/pyharmony
* https://github.com/tuck182/harmony-java-client

Goal
----

The primary intent of this project is to offer quick access to basic controls of the Logitech Harmony Hub via the iOS today view. The widget currently supports:

* Starting activities
* Turning off all activities
* Adjusting the volume
* Pausing and resuming playback
* Fast-forward and rewind

Implementation
--------------

There are two parts to this project:

####iOS App####

![iOS App Screenshot](/../readme_and_wiki_resources/readme_and_wiki_resources/readme/app.png?raw=true)

The app is a configuration tool used to establish the connection with the Logitech Harmony Hub. It requires:

* Valid myharmony.com credentials to obtain a Harmony Hub connection token.
* The Harmony Hub's IP address and port (default 5222).

Once a connection has been successfully established, the configured activities will be displayed.

####Today Extension####

![iOS App Screenshot](/../readme_and_wiki_resources/readme_and_wiki_resources/readme/today_extension.png?raw=true)

Once setup has been completed with the app, the today extension becomes functional and displays the configured activities as well as volume and transport controls, when appropriate.

Maintainers
-----------

[Philippe Boudreau](https://github.com/PBoudreau)

License
-------

HarmonyX is available under the MIT license. See the [LICENSE](https://github.com/PBoudreau/HarmonyX/blob/master/LICENSE) file for more info.
