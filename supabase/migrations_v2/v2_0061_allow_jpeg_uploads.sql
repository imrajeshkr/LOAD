-- =============================================================================
-- v2_0061 — the photo bucket has to accept the format phones actually produce
--
-- exercise-media was created for the catalogue illustrations, which are WebP,
-- so allowed_mime_types was {image/webp, image/png, image/gif}. v2_0055 then
-- opened the bucket for lifters to upload their own exercise photos — and
-- image_picker, on both platforms, hands back JPEG.
--
-- So every photo attached to a user-created exercise was rejected by storage
-- with a mime-type error, the catch that wrapped it discarded the error
-- without logging, demo_path stayed null, and the guide sheet showed the
-- no-artwork placeholder. Nothing in the app said anything had failed.
--
-- image/jpg is included alongside image/jpeg because some clients send the
-- short form and being strict here buys nothing.
-- =============================================================================

update storage.buckets
   set allowed_mime_types = array[
         'image/webp', 'image/png', 'image/gif', 'image/jpeg', 'image/jpg'
       ]
 where id = 'exercise-media';
