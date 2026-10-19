import { application } from "controllers/application"
import PassphraseController from "controllers/passphrase_controller"
import SoyaFormController from "controllers/soya_form_controller"
import IdentifierController from "controllers/identifier_controller"
import NavMenuController from "controllers/nav_menu_controller"
import DismissableController from "controllers/dismissable_controller"
import ResumeController from "controllers/resume_controller"
import ConfirmController from "controllers/confirm_controller"
import CopyController from "controllers/copy_controller"

application.register("passphrase", PassphraseController)
application.register("soya-form", SoyaFormController)
application.register("identifier", IdentifierController)
application.register("nav-menu", NavMenuController)
application.register("dismissable", DismissableController)
application.register("resume", ResumeController)
application.register("confirm", ConfirmController)
application.register("copy", CopyController)
