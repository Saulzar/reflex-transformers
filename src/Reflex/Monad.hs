
-- | Combinators based on the MonadSwitch abstraction, a framework
-- will typically use a stack of Monads based on ReflexM (for pure frameworks).
-- The combinators in this module can then be used to provide monadic switching,
-- sequencing and collections.

module Reflex.Monad 
  ( module Reflex.Monad.Class
  
  , widgetHold
  
  , mapView
  
  , collection
  , collect
  
  , Workflow (..)
  , workflow
  
  , Chain (..)
  , chain
  , (>->)
  
  , loop
  , activity
  
  ) where

import Control.Applicative
import Control.Monad
import Control.Lens

import Data.Monoid
import Data.List
import Data.Functor

import Reflex.Monad.Class
import Reflex.Monad.ReflexM

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map


import Prelude 


  
-- | Hold a monadic widget and update it whenever the Event provides a new
-- monadic widget, swapping out the previously active widget.
-- Returns a Dynamic giving the return values of widgets created
widgetHold :: (MonadSwitch t m) => m a -> Event t (m a) -> m (Dynamic t a)
widgetHold initial e = holdDyn' =<< switchM (Updated initial e)


withIds :: (MonadReflex t m) => [a] -> Event t [a] -> m (Map Int a, Event t (Map Int a))
withIds initial added = do
  total <- current <$> foldDyn (+) (genericLength initial)  (genericLength <$> added)
  return (zipFrom 0 initial, attachWith zipFrom total added)
    where
      zipFrom n = Map.fromList . zip [n..] 
    

-- | Non monadic version of collection, builds a collection from an initial list and a list of updated values
-- items remove themselves upon the event triggering.
-- returns an UpdatedMap with keys assigned to items in ascending order
collect :: (MonadReflex t m) => [(a, Event t ())] -> Event t [(a, Event t ())] -> m (UpdatedMap t Int a)
collect initial added = runReflexM $ collection (pure <$> initial)  (fmap pure <$> added)
    

-- | Builds a collection of widgets from an initial list and events providing new widgets to create
-- as with collect, items remove themselves upon the event triggering.    
-- returns an UpdatedMap with keys assigned to items in ascending order
collection :: (MonadSwitch t m) => [m (a, Event t ())] -> Event t [m (a, Event t ())] -> m (UpdatedMap t Int a)
collection initial added = do 
  (initialMap, addedMap) <- withIds initial added
  rec
    
    (values, remove) <- fmap split <$> switchMapM $ UpdatedMap initialMap $ 
        mergeWith (<>) [ fmap Just <$> addedMap, toRemove ]
      
    toRemove <- switchConcat' $ makeRemovals remove
  return values

  where
    makeRemovals = imap (\k -> fmap $ const $ Map.singleton k Nothing)    
  
  

    
-- | Provides a view into a Dynamic Map value, where sub-views are created using a function passed in
-- returns a Dynamic Map of values returned from child views upon creation.

mapView :: (MonadSwitch t m, Ord k) => Dynamic t (Map k v) -> (k -> Dynamic t v ->  m a) ->  m (Dynamic t (Map k a))
mapView input childView =  do
  inputViews <- mapDyn (Map.mapWithKey itemView) input
  let updates = shallowDiff (current inputViews) (updated inputViews)  

  initial <- sample (current inputViews)
  holdMapDyn =<< switchMapM (UpdatedMap initial updates)
  
  where
    itemView k v = holdDyn v (fmapMaybe (Map.lookup k) (updated input)) >>= childView k  
    
    
    

-- | Recursive Workflow datatype, see 'workflow' below

newtype Workflow t m a = Workflow { unFlow :: m (a, Event t (Workflow t m a)) }


-- | Provide a widget which swaps itself out for another widget upon an event
-- (recursively)
-- Useful if the sequence of widgets needs to return a value (as opposed to passing it 
-- down the chain).

workflow :: (MonadSwitch t m) => Workflow t m a -> m (Dynamic t a)
workflow (Workflow w) = do
  rec 
    result <- widgetHold w $ unFlow <$> switch (snd <$> current result)
  mapDyn fst result        
    
  
  
-- | Provide a way of chaining widgets of type (a -> m (Event t b))
-- where one widgets swaps out the old widget.
-- De-couples the return type as compared to using 'workflow'

chain :: (MonadSwitch t m) => Chain t m a b -> a -> m (Event t b)
chain c a = switchPromptlyDyn <$> workflow (toFlow c a)


-- | Provide a way of looping (a -> m (Event t a)), each iteration switches
-- out the previous iteration.
-- Can be used with Chain to repeat a sequence.
loop :: (MonadSwitch t m) => (a -> m (Event t a)) -> a -> m (Event t a)
loop f a = do
  rec
    e <- switchPromptlyDyn <$> widgetHold (f a) (f <$> e)
    
  return e

  
-- | Run a widget (from an Event) until an Event is recieved.
-- If a second widget arrives before the first is finished, swap it out for the second.
activity :: MonadSwitch t m => Event t (m (Event t a)) -> m (Event t a)
activity e = do
  rec 
    e' <- switch . current <$> 
      (widgetHold (return never) $ leftmost [e, return never <$ e'])
  return e'


-- | Data type wrapping chainable widgets of the type (a -> m (Event t a)) 
data Chain t m a b where
    Chain :: (a -> m (Event t b)) -> Chain t m a b
    (:>>) ::  (a -> m (Event t b)) -> Chain t m b c ->  Chain t m a c
  

infixr 9 >->
infixr 8 :>>

  
-- | Compose two 'Chain' values passing the output event of one 
-- into the construction function of the next.

(>->) :: Chain t m a b -> Chain t m b c -> Chain t m a c  
Chain f    >-> c  =  f :>> c 
(f :>> c') >-> c  =  f :>> (c' >-> c) 

toFlow :: (MonadSwitch t m) => Chain t m a b -> a -> Workflow t m (Event t b)
toFlow (Chain f) a = Workflow $ do 
  e <- f a 
  return (e, end <$ e)
    where end = Workflow $ return (never, never)
    
toFlow (f :>> c) a = Workflow $ do
  e <- f a
  return (never, toFlow c <$> e)
  
  
  
-- sequenceEvents :: (MonadSwitch t m, Ord k) => UpdatedMap k (Event t a -> m (Event t a)) ->  Event t a -> m (Event t a)
-- sequenceEvents items input = do
--   rec 
--     let input k     = switch (previous k <$> b)
--         previous k  = fromMaybe input . Map.lookupLT k
--   
--     b <- holdMap outputs
--     outputs <- holdMapM $ imap (\k f -> f (input k)) items
--     
--   return (switch $ fromMaybe input . fmap fst .  Map.maxView <$> b)
--   
  

