{- git-annex command
 -
 - Copyright 2014 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.View where

import Common.Annex
import Command
import qualified Git
import qualified Git.Command
import qualified Git.Ref
import qualified Git.Branch
import Types.MetaData
import Annex.MetaData
import Types.View
import Annex.View
import Logs.View

def :: [Command]
def = [notBareRepo $ notDirect $
	command "view" paramView seek SectionMetaData "enter a view branch"]

seek :: CommandSeek
seek = withWords start

start :: [String] -> CommandStart
start [] = error "Specify metadata to include in view"
start params = do
	showStart "view" ""
	view <- mkView params
	go view  =<< currentView
  where
	go view Nothing = next $ perform view
	go view (Just v)
		| v == view = stop
		| otherwise = error "Already in a view. Use 'git annex vadd' to further refine this view."

perform :: View -> CommandPerform
perform view = do
	showSideAction "searching"
	next $ checkoutViewBranch view applyView

paramView :: String
paramView = paramPair (paramRepeating "TAG") (paramRepeating "FIELD=VALUE")

{- Parse field=value
 -
 - Note that the field may not be a legal metadata field name,
 - but it's let through anyway.
 - This is useful when matching on directory names with spaces,
 - which are not legal MetaFields.
 -}
parseViewParam :: String -> (MetaField, String)
parseViewParam s = case separate (== '=') s of
	(tag, []) -> (tagMetaField, tag)
	(field, wanted) -> (mkMetaFieldUnchecked field, wanted)

mkView :: [String] -> Annex View
mkView params = do
	v <- View <$> viewbranch <*> pure []
	return $ fst $ refineView v $
		map parseViewParam $ reverse params
  where
	viewbranch = fromMaybe (error "not on any branch!")
		<$> inRepo Git.Branch.current

checkoutViewBranch :: View -> (View -> Annex Git.Branch) -> CommandCleanup
checkoutViewBranch view mkbranch = do
	oldcwd <- liftIO getCurrentDirectory

	{- Change to top of repository before creating view branch. -}
	liftIO . setCurrentDirectory =<< fromRepo Git.repoPath
	branch <- mkbranch view
	
	showOutput
	ok <- inRepo $ Git.Command.runBool
		[ Param "checkout"
		, Param (Git.fromRef $ Git.Ref.base branch)
		]
	when ok $ do
		setView view
		{- A git repo can easily have empty directories in it,
		 - and this pollutes the view, so remove them. -}
		liftIO $ removeemptydirs "."
		unlessM (liftIO $ doesDirectoryExist oldcwd) $ do
			top <- fromRepo Git.repoPath
			showLongNote (cwdmissing top)
	return ok
  where
	removeemptydirs top = mapM_ (tryIO . removeDirectory)
		=<< dirTreeRecursiveSkipping (".git" `isSuffixOf`) top
	cwdmissing top = unlines
		[ "This view does not include the subdirectory you are currently in."
		, "Perhaps you should:  cd " ++ top
		]
